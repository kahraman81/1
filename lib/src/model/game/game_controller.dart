import 'dart:async';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:logging/logging.dart';
import 'package:deep_pick/deep_pick.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';

import 'package:lichess_mobile/src/model/auth/auth_socket.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/socket.dart';
import 'package:lichess_mobile/src/model/common/service/move_feedback.dart';
import 'package:lichess_mobile/src/model/common/service/sound_service.dart';
import 'package:lichess_mobile/src/model/account/account_preferences.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/game/game.dart';
import 'package:lichess_mobile/src/model/game/game_status.dart';
import 'package:lichess_mobile/src/model/game/game_socket_events.dart';
import 'package:lichess_mobile/src/model/game/material_diff.dart';
import 'package:lichess_mobile/src/model/settings/board_preferences.dart';
import 'package:lichess_mobile/src/utils/rate_limit.dart';

part 'game_controller.freezed.dart';
part 'game_controller.g.dart';

@riverpod
class GameController extends _$GameController {
  final _logger = Logger('GameController');

  StreamSubscription<SocketEvent>? _socketSubscription;

  /// Periodic timer when the opponent has left the game, to display the countdown
  /// until the player can claim victory.
  Timer? _opponentLeftCountdownTimer;

  /// Tracks moves that were played on the board, sent to the server, possibly
  /// acked, but without a move response from the server yet.
  /// After a delay, it will trigger a reload. This might fix bugs where the
  /// board is in a transient, dirty state, where clocks don't tick, eventually
  /// causing the player to flag.
  /// It will also help with lila-ws restarts.
  Timer? _transientMoveTimer;

  final _onFlagThrottler = Throttler(const Duration(milliseconds: 500));

  /// Last socket version received
  int? _socketEventVersion;

  /// Last move time
  DateTime? _lastMoveTime;

  @override
  Future<GameState> build(GameFullId gameFullId) {
    final socket = ref.watch(authSocketProvider);
    final (stream, _) = socket.connect(Uri(path: '/play/$gameFullId/v6'));
    _socketEventVersion = null;
    _socketSubscription?.cancel();
    _socketSubscription = stream.listen(_handleSocketEvent);

    ref.onDispose(() {
      _socketSubscription?.cancel();
      _opponentLeftCountdownTimer?.cancel();
      _transientMoveTimer?.cancel();
    });

    return stream.firstWhere((e) => e.topic == 'full').then((event) {
      final fullEvent =
          GameFullEvent.fromJson(event.data as Map<String, dynamic>);

      _socketEventVersion = fullEvent.socketEventVersion;

      return GameState(
        game: fullEvent.game,
        stepCursor: fullEvent.game.steps.length - 1,
        stopClockWaitingForServerAck: false,
      );
    });
  }

  void onUserMove(Move move, {bool? isDrop, bool? isPremove}) {
    final curState = state.requireValue;

    final (newPos, newSan) = curState.game.lastPosition.playToSan(move);
    final sanMove = SanMove(newSan, move);
    final newStep = GameStep(
      ply: curState.game.lastPly + 1,
      position: newPos,
      sanMove: sanMove,
      diff: MaterialDiff.fromBoard(newPos.board),
    );

    final shouldConfirmMove = curState.shouldConfirmMove && isPremove != true;

    state = AsyncValue.data(
      curState.copyWith(
        game: curState.game.copyWith(
          steps: curState.game.steps.add(newStep),
        ),
        stepCursor: curState.stepCursor + 1,
        stopClockWaitingForServerAck: !shouldConfirmMove,
        moveToConfirm: shouldConfirmMove ? move : null,
      ),
    );

    _playMoveFeedback(sanMove, skipAnimationDelay: isDrop ?? false);

    if (!shouldConfirmMove) {
      _sendMoveToSocket(
        move,
        isPremove: isPremove ?? false,
        hasClock: curState.game.clock != null,
        // same logic as web client
        // we want to send client lag only at the beginning of the game when the clock is not running yet
        withLag:
            curState.game.clock != null && curState.activeClockSide == null,
      );
    }
  }

  /// Called if the player cancels the move when confirm move preference is enabled
  void cancelMove() {
    final curState = state.requireValue;
    if (curState.game.steps.isEmpty) {
      assert(false, 'game steps cannot be empty on cancel move');
      return;
    }
    state = AsyncValue.data(
      curState.copyWith(
        game: curState.game.copyWith(
          steps: curState.game.steps.removeLast(),
        ),
        stepCursor: curState.stepCursor - 1,
        moveToConfirm: null,
      ),
    );
  }

  /// Called if the player confirms the move when confirm move preference is enabled
  void confirmMove() {
    final curState = state.requireValue;
    final moveToConfirm = curState.moveToConfirm;
    if (moveToConfirm == null) {
      assert(false, 'moveToConfirm must not be null on confirm move');
      return;
    }

    state = AsyncValue.data(
      curState.copyWith(
        stopClockWaitingForServerAck: true,
        moveToConfirm: null,
      ),
    );
    _sendMoveToSocket(
      moveToConfirm,
      isPremove: false,
      hasClock: curState.game.clock != null,
      // same logic as web client
      // we want to send client lag only at the beginning of the game when the clock is not running yet
      withLag: curState.game.clock != null && curState.activeClockSide == null,
    );
  }

  /// Set or unset a premove.
  void setPremove(cg.Move? move) {
    final curState = state.requireValue;
    state = AsyncValue.data(
      curState.copyWith(
        premove: move,
      ),
    );
  }

  void cursorAt(int cursor) {
    if (state.hasValue) {
      state = AsyncValue.data(state.requireValue.copyWith(stepCursor: cursor));
      final san = state.requireValue.game.stepAt(cursor).sanMove?.san;
      if (san != null) {
        _playReplayMoveSound(san);
        HapticFeedback.lightImpact();
      }
    }
  }

  void cursorForward() {
    if (state.hasValue) {
      final curState = state.requireValue;
      if (curState.stepCursor < curState.game.steps.length - 1) {
        state = AsyncValue.data(
          curState.copyWith(stepCursor: curState.stepCursor + 1),
        );
        final san = curState.game.stepAt(curState.stepCursor + 1).sanMove?.san;
        if (san != null) {
          _playReplayMoveSound(san);
        }
      }
    }
  }

  void cursorBackward() {
    if (state.hasValue) {
      final curState = state.requireValue;
      if (curState.stepCursor > 0) {
        state = AsyncValue.data(
          curState.copyWith(stepCursor: curState.stepCursor - 1),
        );
        final san = curState.game.stepAt(curState.stepCursor - 1).sanMove?.san;
        if (san != null) {
          _playReplayMoveSound(san);
        }
      }
    }
  }

  void toggleMoveConfirmation() {
    final curState = state.requireValue;
    state = AsyncValue.data(
      curState.copyWith(
        moveConfirmSettingOverride:
            !(curState.moveConfirmSettingOverride ?? true),
      ),
    );
  }

  void toggleZenMode() {
    final curState = state.requireValue;
    state = AsyncValue.data(
      curState.copyWith(
        zenModeGameSetting: !(curState.zenModeGameSetting ?? false),
      ),
    );
  }

  void onFlag() {
    _onFlagThrottler(() {
      if (state.hasValue) {
        _socket.send('flag', state.requireValue.game.youAre?.name);
      }
    });
  }

  void moreTime() {
    _socket.send('moretime', null);
  }

  void abortGame() {
    _socket.send('abort', null);
  }

  void resignGame() {
    _socket.send('resign', null);
  }

  void forceResign() {
    _socket.send('resign-force', null);
  }

  void forceDraw() {
    _socket.send('draw-force', null);
  }

  void claimDraw() {
    _socket.send('draw-claim', null);
  }

  void offerOrAcceptDraw() {
    _socket.send('draw-yes', null);
  }

  void cancelOrDeclineDraw() {
    _socket.send('draw-no', null);
  }

  void offerTakeback() {
    _socket.send('takeback-yes', null);
  }

  void acceptTakeback() {
    _socket.send('takeback-yes', null);
    setPremove(null);
  }

  void cancelOrDeclineTakeback() {
    _socket.send('takeback-no', null);
  }

  void proposeOrAcceptRematch() {
    _socket.send('rematch-yes', null);
  }

  void declineRematch() {
    _socket.send('rematch-no', null);
  }

  void _sendMoveToSocket(
    Move move, {
    required bool isPremove,
    required bool hasClock,
    required bool withLag,
  }) {
    final moveTime = hasClock
        ? isPremove == true
            ? Duration.zero
            : _lastMoveTime != null
                ? DateTime.now().difference(_lastMoveTime!)
                : null
        : null;
    _socket.send(
      'move',
      {
        'u': move.uci,
        if (moveTime != null)
          's': (moveTime.inMilliseconds * 0.1).round().toRadixString(36),
      },
      ackable: true,
      withLag: hasClock && (moveTime == null || withLag),
    );

    _transientMoveTimer = Timer(const Duration(seconds: 10), _resyncGameData);
  }

  /// Move feedback while playing
  void _playMoveFeedback(SanMove sanMove, {bool skipAnimationDelay = false}) {
    final animationDuration =
        ref.read(boardPreferencesProvider).pieceAnimationDuration;

    final delay = animationDuration - const Duration(milliseconds: 10);

    if (skipAnimationDelay || delay <= Duration.zero) {
      _moveFeedback(sanMove);
    } else {
      Timer(delay, () {
        _moveFeedback(sanMove);
      });
    }
  }

  void _moveFeedback(SanMove sanMove) {
    final isCheck = sanMove.san.contains('+');
    if (sanMove.san.contains('x')) {
      ref.read(moveFeedbackServiceProvider).captureFeedback(check: isCheck);
    } else {
      ref.read(moveFeedbackServiceProvider).moveFeedback(check: isCheck);
    }
  }

  /// Play the sound when replaying moves
  void _playReplayMoveSound(String san) {
    final soundService = ref.read(soundServiceProvider);
    if (san.contains('x')) {
      soundService.play(Sound.capture);
    } else {
      soundService.play(Sound.move);
    }
  }

  /// Resync full game data with the server
  void _resyncGameData() {
    _logger.info('Resyncing game data');
    _socket.connect(Uri(path: '/play/$gameFullId/v6'), forceReconnect: true);
  }

  void _handleSocketEvent(SocketEvent event) {
    final currentEventVersion = _socketEventVersion;

    /// We don't have a version yet, let's wait for the full event
    if (currentEventVersion == null) {
      return;
    }

    if (event.version != null) {
      if (event.version! <= currentEventVersion) {
        _logger.fine('Already handled event ${event.version}');
        return;
      }
      if (event.version! > currentEventVersion + 1) {
        _logger.warning(
          'Event gap detected from $currentEventVersion to ${event.version}',
        );
        _resyncGameData();
      }
      _socketEventVersion = event.version;
    }

    _handleSocketTopic(event);
  }

  void _handleSocketTopic(SocketEvent event) {
    if (!state.hasValue) {
      assert(false, 'received a game SocketEvent while GameState is null');
      return;
    }

    switch (event.topic) {
      // Server asking for a resync
      case 'resync':
        _resyncGameData();

      // Server asking for a reload, or in some cases the reload itself contains
      // another topic message
      case 'reload':
        if (event.data is Map<String, dynamic>) {
          final data = event.data as Map<String, dynamic>;
          if (data['t'] == null) {
            _resyncGameData();
            return;
          }
          final reloadEvent = SocketEvent(
            topic: data['t'] as String,
            data: data['d'],
          );
          _handleSocketTopic(reloadEvent);
        } else {
          _resyncGameData();
        }

      // Full game data, received after a (re)connection to game socket
      case 'full':
        final fullEvent =
            GameFullEvent.fromJson(event.data as Map<String, dynamic>);

        if (_socketEventVersion != null &&
            fullEvent.socketEventVersion < _socketEventVersion!) {
          return;
        }
        _socketEventVersion = fullEvent.socketEventVersion;
        _lastMoveTime = null;

        state = AsyncValue.data(
          GameState(
            game: fullEvent.game,
            stepCursor: fullEvent.game.steps.length - 1,
            stopClockWaitingForServerAck: false,
            // cancel the premove to avoid playing wrong premove when the full
            // game data is reloaded
            premove: null,
          ),
        );

      // Move event, received after sending a move or receiving a move from the
      // opponent
      case 'move':
        final curState = state.requireValue;
        final data = MoveEvent.fromJson(event.data as Map<String, dynamic>);
        final playedSide = data.ply.isOdd ? Side.white : Side.black;

        GameState newState = curState.copyWith(
          game: curState.game.copyWith(
            isThreefoldRepetition: data.threefold,
            winner: data.winner,
            status: data.status ?? curState.game.status,
          ),
        );

        if (playedSide == curState.game.youAre) {
          _transientMoveTimer?.cancel();
        }

        // add opponent move
        if (data.ply == curState.game.lastPly + 1) {
          final lastPos = curState.game.lastPosition;
          final move = Move.fromUci(data.uci)!;
          final sanMove = SanMove(data.san, move);
          final newPos = lastPos.playUnchecked(move);
          final newStep = GameStep(
            ply: data.ply,
            sanMove: sanMove,
            position: newPos,
            diff: MaterialDiff.fromBoard(newPos.board),
          );

          newState = newState.copyWith(
            game: newState.game.copyWith(
              steps: newState.game.steps.add(newStep),
            ),
          );

          if (!curState.isReplaying) {
            newState = newState.copyWith(
              stepCursor: newState.stepCursor + 1,
            );

            _playMoveFeedback(sanMove);
          }
        }

        // TODO handle delay
        if (newState.game.clock != null && data.clock != null) {
          _lastMoveTime = DateTime.now();
          newState = newState.copyWith.game.clock!(
            white: data.clock!.white,
            black: data.clock!.black,
          );
          newState = newState.copyWith(
            stopClockWaitingForServerAck: false,
          );
        }

        if (newState.game.expiration != null) {
          if (newState.game.steps.length > 2) {
            newState = newState.copyWith.game(
              expiration: null,
            );
          } else {
            newState = newState.copyWith.game(
              expiration: (
                idle: newState.game.expiration!.idle,
                timeToMove: curState.game.expiration!.timeToMove,
                movedAt: DateTime.now(),
              ),
            );
          }
        }
        state = AsyncValue.data(newState);

      // End game event
      case 'endData':
        final endData =
            GameEndEvent.fromJson(event.data as Map<String, dynamic>);
        final curState = state.requireValue;
        GameState newState = curState.copyWith(
          game: curState.game.copyWith(
            status: endData.status,
            winner: endData.winner,
            boosted: endData.boosted,
            white: curState.game.white.copyWith(
              ratingDiff: endData.ratingDiff?.white,
            ),
            black: curState.game.black.copyWith(
              ratingDiff: endData.ratingDiff?.black,
            ),
          ),
          premove: null,
        );

        if (endData.clock != null) {
          newState = newState.copyWith.game.clock!(
            white: endData.clock!.white,
            black: endData.clock!.black,
          );
        }

        if (curState.game.lastPosition.fullmoves > 1) {
          Timer(const Duration(milliseconds: 500), () {
            ref.read(soundServiceProvider).play(Sound.dong);
          });
        }
        state = AsyncValue.data(newState);

      case 'clockInc':
        final data = event.data as Map<String, dynamic>;
        final side = pick(data['color']).asSideOrNull();
        final newClock = pick(data['total'])
            .letOrNull((it) => Duration(milliseconds: it.asIntOrThrow() * 10));
        final curState = state.requireValue;
        if (side != null && newClock != null) {
          final newState = side == Side.white
              ? curState.copyWith.game.clock!(
                  white: newClock,
                )
              : curState.copyWith.game.clock!(
                  black: newClock,
                );
          state = AsyncValue.data(newState);
        }

      // Crowd event, sent when a player quits or joins the game
      case 'crowd':
        final data = event.data as Map<String, dynamic>;
        final whiteOnGame = data['white'] as bool?;
        final blackOnGame = data['black'] as bool?;
        final curState = state.requireValue;
        final opponent = curState.game.youAre?.opposite;
        GameState newState = curState;
        if (whiteOnGame != null) {
          newState = newState.copyWith.game(
            white: newState.game.white.setOnGame(whiteOnGame),
          );
          if (opponent == Side.white && whiteOnGame == true) {
            _opponentLeftCountdownTimer?.cancel();
            newState = newState.copyWith(
              opponentLeftCountdown: null,
            );
          }
        }
        if (blackOnGame != null) {
          newState = newState.copyWith.game(
            black: newState.game.black.setOnGame(blackOnGame),
          );
          if (opponent == Side.black && blackOnGame == true) {
            _opponentLeftCountdownTimer?.cancel();
            newState = newState.copyWith(
              opponentLeftCountdown: null,
            );
          }
        }
        state = AsyncValue.data(newState);

      // Gone event, sent when the opponent has quit the game for long enough
      // than we can claim victory
      case 'gone':
        final isGone = event.data as bool;
        _opponentLeftCountdownTimer?.cancel();
        GameState newState = state.requireValue;
        final youAre = newState.game.youAre;
        newState = newState.copyWith.game(
          white: youAre == Side.white
              ? newState.game.white
              : newState.game.white.setGone(isGone),
          black: youAre == Side.black
              ? newState.game.black
              : newState.game.black.setGone(isGone),
        );
        state = AsyncValue.data(newState);

      // Event sent when the opponent has quit the game, to display a countdown
      // before claiming victory is possible
      case 'goneIn':
        final timeLeft = Duration(seconds: event.data as int);
        state = AsyncValue.data(
          state.requireValue.copyWith(
            opponentLeftCountdown: timeLeft,
          ),
        );
        _opponentLeftCountdownTimer?.cancel();
        _opponentLeftCountdownTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) {
            final curState = state.requireValue;
            final opponentLeftCountdown = curState.opponentLeftCountdown;
            if (opponentLeftCountdown == null) {
              _opponentLeftCountdownTimer?.cancel();
            } else if (!curState.canShowClaimWinCountdown) {
              _opponentLeftCountdownTimer?.cancel();
              state = AsyncValue.data(
                curState.copyWith(
                  opponentLeftCountdown: null,
                ),
              );
            } else {
              final newTime =
                  opponentLeftCountdown - const Duration(seconds: 1);
              if (newTime <= Duration.zero) {
                _opponentLeftCountdownTimer?.cancel();
                state = AsyncValue.data(
                  curState.copyWith(opponentLeftCountdown: null),
                );
              }
              state = AsyncValue.data(
                curState.copyWith(opponentLeftCountdown: newTime),
              );
            }
          },
        );

      // Event sent when a player adds or cancels a draw offer
      case 'drawOffer':
        final side = pick(event.data).asSideOrNull();
        final curState = state.requireValue;
        state = AsyncValue.data(
          curState.copyWith(
            lastDrawOfferAtPly: side != null && side == curState.game.youAre
                ? curState.game.lastPly
                : null,
            game: curState.game.copyWith(
              white: curState.game.white.copyWith(
                offeringDraw: side == null ? null : side == Side.white,
              ),
              black: curState.game.black.copyWith(
                offeringDraw: side == null ? null : side == Side.black,
              ),
            ),
          ),
        );

      // Event sent when a player adds or cancels a takeback offer
      case 'takebackOffers':
        final data = event.data as Map<String, dynamic>;
        final white = pick(data['white']).asBoolOrNull();
        final black = pick(data['black']).asBoolOrNull();
        final curState = state.requireValue;
        state = AsyncValue.data(
          curState.copyWith(
            game: curState.game.copyWith(
              white: curState.game.white.copyWith(
                proposingTakeback: white ?? false,
              ),
              black: curState.game.black.copyWith(
                proposingTakeback: black ?? false,
              ),
            ),
          ),
        );

      // Event sent when a player adds or cancels a rematch offer
      case 'rematchOffer':
        final side = pick(event.data).asSideOrNull();
        final curState = state.requireValue;
        state = AsyncValue.data(
          curState.copyWith(
            game: curState.game.copyWith(
              white: curState.game.white.copyWith(
                offeringRematch: side == null ? null : side == Side.white,
              ),
              black: curState.game.black.copyWith(
                offeringRematch: side == null ? null : side == Side.black,
              ),
            ),
          ),
        );

      // Event sent when a rematch is taken. Not used for now, except to prevent
      // sending another rematch offer, which should not happen
      case 'rematchTaken':
        final nextId = pick(event.data).asGameIdOrThrow();
        state = AsyncValue.data(
          state.requireValue.copyWith.game(
            rematch: nextId,
          ),
        );

      // Event sent after a rematch is taken, to redirect to the new game
      case 'redirect':
        final data = event.data as Map<String, dynamic>;
        final fullId = pick(data['id']).asGameFullIdOrThrow();
        state = AsyncValue.data(
          state.requireValue.copyWith(
            redirectGameId: fullId,
          ),
        );
    }
  }

  AuthSocket get _socket => ref.read(authSocketProvider);
}

@freezed
class GameState with _$GameState {
  const GameState._();

  const factory GameState({
    required PlayableGame game,
    required int stepCursor,
    int? lastDrawOfferAtPly,
    Duration? opponentLeftCountdown,
    required bool stopClockWaitingForServerAck,
    cg.Move? premove,

    /// Game only setting to override the account preference
    bool? moveConfirmSettingOverride,

    /// Zen mode setting if account preference is set to [Zen.gameAuto]
    bool? zenModeGameSetting,

    /// Set if confirm move preference is enabled and player played a move
    Move? moveToConfirm,

    /// Game full id used to redirect to the new game of the rematch
    GameFullId? redirectGameId,
  }) = _GameState;

  // preferences
  bool get isZenModeEnabled =>
      zenModeGameSetting ?? game.prefs?.zenMode == Zen.yes;
  bool get canPremove => game.prefs?.enablePremove ?? true;
  bool get canAutoQueen => game.prefs?.autoQueen == AutoQueen.always;
  bool get canAutoQueenOnPremove => game.prefs?.autoQueen == AutoQueen.premove;
  bool get shouldConfirmResignAndDrawOffer => game.prefs?.confirmResign ?? true;
  bool get shouldConfirmMove =>
      moveConfirmSettingOverride ?? game.prefs?.submitMove ?? false;

  // game state
  bool get isReplaying => stepCursor < game.steps.length - 1;
  bool get canGoForward => stepCursor < game.steps.length - 1;
  bool get canGoBackward => stepCursor > 0;

  bool get canGetNewOpponent =>
      !game.playable &&
      (game.meta.source == GameSource.lobby ||
          game.meta.source == GameSource.pool);

  bool get canOfferDraw =>
      game.drawable && (lastDrawOfferAtPly ?? -99) < game.lastPly - 20;

  bool get canShowClaimWinCountdown =>
      !game.isPlayerTurn &&
      game.resignable &&
      (game.meta.rules == null ||
          !game.meta.rules!.contains(GameRule.noClaimWin));

  bool get canOfferRematch =>
      game.rematch == null &&
      game.rematchable &&
      (game.finished ||
          (game.aborted &&
              (!game.meta.rated ||
                  !{GameSource.lobby, GameSource.pool}
                      .contains(game.meta.source)))) &&
      game.boosted != true;

  /// Time left to move for the active player if an expiration is set
  Duration? get timeToMove {
    if (!game.playable || game.expiration == null) {
      return null;
    }
    final timeLeft = game.expiration!.movedAt.difference(DateTime.now()) +
        game.expiration!.timeToMove;

    if (timeLeft.isNegative) {
      return Duration.zero;
    }
    return timeLeft;
  }

  Side? get activeClockSide {
    if (game.clock == null) {
      return null;
    }

    if (stopClockWaitingForServerAck) {
      return null;
    }

    if (game.status == GameStatus.started) {
      final pos = game.lastPosition;
      if (pos.fullmoves > 1) {
        return moveToConfirm != null ? pos.turn.opposite : pos.turn;
      }
    }

    return null;
  }

  AnalysisOptions get analysisOptions => AnalysisOptions(
        isLocalEvaluationAllowed: true,
        variant: game.meta.variant,
        initialFen: game.initialPosition.fen,
        initialPly: game.initialPly,
        moves: IList(
          game.steps
              .where((e) => e.sanMove != null)
              .map((e) => e.sanMove!.move),
        ),
        initialMoveCursor: stepCursor,
        orientation: game.youAre ?? Side.white,
        id: game.meta.id,
      );
}

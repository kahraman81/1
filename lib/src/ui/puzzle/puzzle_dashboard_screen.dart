import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lichess_mobile/src/common/connectivity.dart';
import 'package:lichess_mobile/src/common/lichess_icons.dart';
import 'package:lichess_mobile/src/common/styles.dart';
import 'package:lichess_mobile/src/widgets/buttons.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:lichess_mobile/src/utils/l10n_context.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_theme.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_providers.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';

import 'puzzle_screen.dart';
import 'puzzle_themes_screen.dart';
import 'puzzle_streak_screen.dart';

class PuzzleDashboardScreen extends StatelessWidget {
  const PuzzleDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformWidget(
      androidBuilder: _androidBuilder,
      iosBuilder: _iosBuilder,
    );
  }

  Widget _androidBuilder(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.puzzles),
      ),
      body: const Center(child: _Body()),
    );
  }

  Widget _iosBuilder(BuildContext context) {
    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(context.l10n.puzzles),
          ),
          const SliverSafeArea(
            top: false,
            sliver: _Body(),
          ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = PuzzleTheme.mix;
    final nextPuzzle = ref.watch(nextPuzzleProvider(theme));
    final connectivity = ref.watch(connectivityChangesProvider);

    final content = [
      Padding(
        padding: Styles.bodySectionPadding,
        child: nextPuzzle.when(
          data: (data) {
            if (data == null) {
              return const _PuzzleButton(
                theme: theme,
                subtitle: 'Could not find any puzzle! Go online to get more.',
              );
            } else {
              return _PuzzleButton(
                theme: theme,
                onTap: () {
                  pushPlatformRoute(
                    context,
                    rootNavigator: true,
                    builder: (context) => PuzzleScreen(
                      theme: theme,
                      initialPuzzleContext: data,
                    ),
                  ).then((_) {
                    ref.invalidate(nextPuzzleProvider(theme));
                  });
                },
              );
            }
          },
          loading: () => const _PuzzleButton(theme: theme),
          error: (e, s) {
            debugPrint(
              'SEVERE: [PuzzleScreen] could not load next puzzle; $e\n$s',
            );
            return const _PuzzleButton(theme: theme);
          },
        ),
      ),
      Padding(
        padding: Styles.bodySectionBottomPadding,
        child: CardButton(
          icon: const Icon(LichessIcons.target, size: 44),
          title: Text(context.l10n.puzzlePuzzleThemes),
          subtitle: const Text('Play puzzles from a specific theme.'),
          onTap: () {
            pushPlatformRoute(
              context,
              builder: (context) => const PuzzleThemesScreen(),
            );
          },
        ),
      ),
      Padding(
        padding: Styles.bodySectionBottomPadding,
        child: CardButton(
          icon: const Icon(LichessIcons.streak, size: 44),
          title: const Text('Puzzle Streak'),
          subtitle: Text(context.l10n.puzzleStreakDescription),
          onTap: connectivity.when(
            data: (data) => data.isOnline
                ? () {
                    pushPlatformRoute(
                      context,
                      rootNavigator: true,
                      builder: (context) => const PuzzleStreakScreen(),
                    );
                  }
                : null,
            loading: () => null,
            error: (_, __) => null,
          ),
        ),
      ),
    ];

    return defaultTargetPlatform == TargetPlatform.iOS
        ? SliverList(delegate: SliverChildListDelegate(content))
        : ListView(children: content);
  }
}

class _PuzzleButton extends StatelessWidget {
  const _PuzzleButton({
    required this.theme,
    this.onTap,
    this.subtitle,
  });

  final PuzzleTheme theme;
  final VoidCallback? onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return CardButton(
      icon: const Icon(LichessIcons.target, size: 44),
      title: Text(
        puzzleThemeL10n(context, theme).name,
        style: Styles.sectionTitle,
      ),
      subtitle: Text(subtitle ?? puzzleThemeL10n(context, theme).description),
      onTap: onTap,
    );
  }
}

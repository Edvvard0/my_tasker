import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Заставка, пока открывается БД и читаются токены.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('splash'),
    color: context.colors.bgBase,
    child: const SizedBox.expand(),
  );
}

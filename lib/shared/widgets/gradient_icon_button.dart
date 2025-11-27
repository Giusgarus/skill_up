import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class GradientIconButton extends StatelessWidget {
  const GradientIconButton({
    super.key,
    required this.onTap,
    this.width = 100,
    this.height = 56,
    this.iconSize = 32,
    this.iconAsset = 'assets/icons/send_icon.svg',
  });

  final VoidCallback onTap;
  final double width;
  final double height;
  final double iconSize;
  final String iconAsset;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: SvgPicture.asset(
          iconAsset,
          width: iconSize,
          height: iconSize,
          colorFilter: const ColorFilter.mode(
            Colors.white,
            BlendMode.srcIn,
          ),
        ),
      ),
    );
  }
}
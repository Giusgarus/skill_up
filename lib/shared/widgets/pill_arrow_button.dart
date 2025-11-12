import 'package:flutter/material.dart';

class PillArrowButton extends StatelessWidget {
  const PillArrowButton({
    super.key,
    required this.onPressed,
    this.loading = false,
    this.tooltip,
    this.width = 88,
    this.height = 54,
  });

  final VoidCallback? onPressed;
  final bool loading;
  final String? tooltip;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !loading;

    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(height / 2), // pillola
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: loading
          ? const SizedBox(
        width: 22, height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
        ),
      )
          : Transform.translate( // piccolo nudge per centratura ottica
        offset: const Offset(1.5, 0),
        child: const Icon(
          Icons.play_arrow_rounded, // triangolo “tondeggiante”
          size: 32,
          color: Colors.black,
        ),
      ),
    );

    final wrapped = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(height / 2),
        child: button,
      ),
    );

    return tooltip == null
        ? wrapped
        : Tooltip(message: tooltip!, child: wrapped);
  }
}
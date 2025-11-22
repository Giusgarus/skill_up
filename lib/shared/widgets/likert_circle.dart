import 'package:flutter/material.dart';

class LikertCircle extends StatelessWidget {
  const LikertCircle({
    super.key,
    required this.filled,
    required this.onTap,
  });

  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!filled) {
      // Stato NON selezionato: bianco + bordo nero
      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(
              color: Colors.black,
              width: 3,
            ),
          ),
        ),
      );
    }

    // Stato selezionato → cerchio bianco + PNG centrato
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 54,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white, // ⬅️ sfondo bianco dietro all'immagine
        ),
        child: Center(
          child: Image.asset(
            'assets/icons/task_done_icon.png',
            width: 54,
            height: 54,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
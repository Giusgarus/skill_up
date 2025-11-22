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
      // 👉 Stato NON selezionato: bianco + bordo nero
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

    // 👉 Stato SELEZIONATO: anello con gradiente + centro bianco
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 54,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 42, // leggermente più piccolo → crea l'anello
            height: 42,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
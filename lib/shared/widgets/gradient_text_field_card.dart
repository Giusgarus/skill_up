import 'package:flutter/material.dart';

class GradientTextFieldCard extends StatelessWidget {
  const GradientTextFieldCard({
    super.key,
    required this.controller,
    required this.hintText,
    this.maxLines = 4,
    this.minLines = 2,
    this.autofocus = true,
  });

  final TextEditingController controller;
  final String hintText;
  final int maxLines;
  final int minLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          width: 2,
          color: Colors.transparent,
        ),
        gradient: const LinearGradient(
          colors: [
            Color(0xFFFF9A9E),
            Color(0xFFFFCF71),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          maxLines: maxLines,
          minLines: minLines,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: hintText,
            border: InputBorder.none,
            hintStyle: const TextStyle(
              fontFamily: 'FiraCode',
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Color(0x99000000),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          style: const TextStyle(
            fontFamily: 'FiraCode',
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.3,
            color: Colors.black,
          ),
        ),
      ),
    );
  }
}
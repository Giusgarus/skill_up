import 'package:flutter/material.dart';

/// Small bold label displayed above inputs.
class FieldLabel extends StatelessWidget {
  final String text;
  const FieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w900,
        fontSize: 18,
        color: Colors.black.withOpacity(0.9),
      ),
    );
  }
}
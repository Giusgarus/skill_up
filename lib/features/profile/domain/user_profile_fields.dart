import 'package:flutter/material.dart';

class UserProfileField {
  const UserProfileField({
    required this.id,
    required this.label,
    required this.hint,
    this.maxLines = 1,
    this.spacing = 22,
    this.keyboardType,
  });

  final String id;
  final String label;
  final String hint;
  final int maxLines;
  final double spacing;
  final TextInputType? keyboardType;
}

const List<UserProfileField> kUserProfileFields = [
  UserProfileField(
    id: 'username',
    label: 'Your username',
    hint: 'Enter username',
  ),
  UserProfileField(
    id: 'name',
    label: 'Your name',
    hint: 'Enter name',
  ),
  UserProfileField(
    id: 'gender',
    label: 'Your gender',
    hint: 'Enter gender',
  ),
  UserProfileField(
    id: 'weight',
    label: 'Your weight',
    hint: 'Enter weight',
    keyboardType: TextInputType.number,
  ),
  UserProfileField(
    id: 'height',
    label: 'Your height',
    hint: 'Enter height',
    spacing: 28,
    keyboardType: TextInputType.number,
  ),
  UserProfileField(
    id: 'about',
    label: 'Briefly describe yourself',
    hint: 'Type a short bio',
    maxLines: 5,
    spacing: 26,
    keyboardType: TextInputType.multiline,
  ),
  UserProfileField(
    id: 'day_routine',
    label: 'Briefly explain what you do during the day',
    hint: 'Describe your daily routine',
    maxLines: 4,
    spacing: 26,
    keyboardType: TextInputType.multiline,
  ),
  UserProfileField(
    id: 'organized',
    label: 'Generally an organized or disorganized person?',
    hint: 'Share your thoughts',
    maxLines: 4,
    spacing: 26,
    keyboardType: TextInputType.multiline,
  ),
  UserProfileField(
    id: 'focus',
    label:
        'What helps you stay focused when you\'re doing something you don\'t like doing?',
    hint: 'Talk about your focus boosters',
    maxLines: 4,
    spacing: 40,
    keyboardType: TextInputType.multiline,
  ),
];

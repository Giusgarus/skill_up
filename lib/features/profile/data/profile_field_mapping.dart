const Map<String, String> _frontendToBackendProfileFields = {
  'username': 'username',
  'name': 'name',
  'gender': 'sex',
  'age': 'age',
  'weight': 'weight',
  'height': 'height',
  'about': 'about',
  'day_routine': 'day_routine',
  'organized': 'organized',
  'focus': 'focus',
  'onboarding_answers': 'onboarding_answers',
};

final Map<String, String> _backendToFrontendProfileFields = {
  for (final entry in _frontendToBackendProfileFields.entries)
    entry.value: entry.key,
};

/// Resolves a UI field identifier to the corresponding backend attribute name.
String? backendAttributeForField(String fieldId) {
  return _frontendToBackendProfileFields[fieldId];
}

/// Resolves a backend attribute name to the matching UI field identifier.
String? frontendFieldForAttribute(String attribute) {
  return _backendToFrontendProfileFields[attribute];
}

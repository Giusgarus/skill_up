const Map<String, String> _frontendToBackendProfileFields = {
  'username': 'surname',
  'name': 'name',
  'gender': 'sex',
  'weight': 'weight',
  'height': 'height',
  'about': 'info1',
  'day_routine': 'info2',
  'organized': 'info3',
  'focus': 'info4',
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

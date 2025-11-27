const Map<String, List<String>> kInterestGoalSuggestions = {
  "health": ["Build strength", "Reach goal wt", "More energy", "Better sleep"],
  "mindfulness": [
    "Less stress",
    "Daily meditate",
    "Daily gratitude",
    "Emo regulation",
  ],
  "productivity": ["Deep focus", "No procrast.", "Time mgmt", "AM/PM routine"],
  "career": [
    "Get promotion",
    "Learn job skill",
    "Grow network",
    "Work-life bal.",
  ],
  "learning": ["Read more", "Learn language", "New hobby", "Better memory"],
  "financial": [
    "Save for goal",
    "Pay off debt",
    "Follow budget",
    "Start invest.",
  ],
  "creativity": [
    "Create daily",
    "Unblock creat.",
    "Finish project",
    "Write/journal",
  ],
  "sociality": ["New friends", "Deeper bonds", "Better comms", "Social conf."],
  "home": ["Tidy home", "Declutter", "Meal prep", "Calm home"],
  "digital detox": [
    "Less screen",
    "Quit soc. med",
    "No phone bed",
    "Be present",
  ],
};

const List<String> _fallbackInterests = [
  "health",
  "mindfulness",
  "productivity",
  "career",
];

List<String> buildGoalSuggestions(List<String> interests, {int maxItems = 4}) {
  final normalizedInterests = interests
      .map((label) => label.trim().toLowerCase())
      .where((label) => kInterestGoalSuggestions.containsKey(label))
      .toList();

  final sourceInterests = normalizedInterests.isEmpty
      ? _fallbackInterests
      : normalizedInterests;
  final offsets = {for (final interest in sourceInterests) interest: 0};

  final suggestions = <String>[];
  while (suggestions.length < maxItems) {
    var addedThisRound = false;
    for (final interest in sourceInterests) {
      final options = kInterestGoalSuggestions[interest]!;
      final index = offsets[interest] ?? 0;
      if (index < options.length) {
        suggestions.add(options[index]);
        offsets[interest] = index + 1;
        addedThisRound = true;
      }
      if (suggestions.length >= maxItems) break;
    }
    if (!addedThisRound) break; // no more options available
  }

  return suggestions.take(maxItems).toList();
}

const Map<String, List<String>> kInterestGoalSuggestions = {
  "health": [
    "Build Strength & Muscle: Focus on workouts and protein.",
    "Reach Ideal Weight: Focus on calorie deficit/management and cardio.",
    "Boost Energy Levels: Focus on nutrition quality and hydration.",
    "Improve Sleep Quality: Focus on rest and recovery routines.",
  ],
  "mindfulness": [
    "Reduce Stress & Anxiety: Techniques to calm the nervous system.",
    "Start Meditating: Building a consistent daily practice.",
    "Practice Gratitude: Shifting mindset to positivity.",
    "Emotional Regulation: Learning to handle mood swings and anger.",
  ],
  "productivity": [
    "Deep Focus & Flow: Eliminating distractions for deep work.",
    "Stop Procrastinating: Tools to start tasks immediately.",
    "Master Time Management: Scheduling and prioritizing effectively.",
    "Morning/Evening Routine: Building bookends for a successful day.",
  ],
  "career": [
    "Get Promoted/Raise: High-performance habits for advancement.",
    "Learn New Job Skills: Upskilling for the current or future role.",
    "Grow Network: Building professional connections.",
    "Work-Life Balance: Setting boundaries to prevent burnout.",
  ],
  "learning": [
    "Read More Books: Building a consistent reading habit.",
    "Learn a Language: Daily practice for fluency.",
    "Master a New Hobby: Dedicated practice time for a specific skill.",
    "Improve Memory: Brain training and cognitive retention.",
  ],
  "financial": [
    "Save for a Goal: Building an emergency fund or specific savings.",
    "Pay Off Debt: Aggressive repayment strategies.",
    "Stick to a Budget: Daily tracking and spending discipline.",
    "Start Investing: Learning market basics and regular contributions.",
  ],
  "creativity": [
    "Daily Creative Practice: committing to 15-30 mins of art/creation.",
    "Overcome Creative Block: Habits to spark inspiration.",
    "Finish a Project: Discipline to complete what was started.",
    "Journal/Write Daily: Expressing thoughts through words.",
  ],
  "sociality": [
    "Make New Friends: Putting oneself in social situations.",
    "Deepen Relationships: Connecting better with current friends/partners.",
    "Better Communication: Active listening and clear speaking.",
    "Social Confidence: Overcoming shyness and anxiety.",
  ],
  "home": [
    "Keep a Tidy Home: Daily maintenance and cleaning routines.",
    "Declutter & Minimize: Reducing possessions and organizing.",
    "Meal Planning/Prep: Organizing food to save time and mess.",
    "Create a Sanctuary: Making the home a relaxing environment.",
  ],
  "digital detox": [
    "Reduce Screen Time: Hard limits on daily phone usage.",
    "Quit Social Media: Stopping the scroll and deleting apps.",
    "No Phone in Bedroom: Improving sleep hygiene.",
    "Be More Present: Engaging with the real world without tech.",
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

  final sourceInterests =
      normalizedInterests.isEmpty ? _fallbackInterests : normalizedInterests;
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

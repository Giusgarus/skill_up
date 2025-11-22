import 'package:flutter/material.dart';

class PlanOverviewPage extends StatefulWidget {
  const PlanOverviewPage({super.key});

  static const route = '/planOverview';

  @override
  State<PlanOverviewPage> createState() => _PlanOverviewPageState();
}

class _PlanOverviewPageState extends State<PlanOverviewPage> {
  // Placeholder data for the workout plan
  final List<Map<String, dynamic>> _planData = [
    {
      'weekTitle': 'Week 1: Foundation (Very Light)',
      'days': [
        {
          'date': 'Tuesday, 21 October 2025',
          'category': 'Upper & Core',
          'exercises': [
            'Knee Push-ups: 2 sets of 8 reps',
            'Plank: 2 sets, hold for 20 seconds',
            'Crunches: 2 sets of 15 reps',
          ],
        },
        {
          'date': 'Thursday, 23 October 2025',
          'category': 'Lower & Cardio',
          'exercises': [
            'Bodyweight Squats: 2 sets of 12 reps',
            'Alternating Lunges: 2 sets of 8 reps per leg',
            'Glute Bridges: 2 sets of 15 reps',
          ],
        },
        {
          'date': 'Saturday, 25 October 2025',
          'category': 'Upper & Core',
          'exercises': [
            'Knee Push-ups: 2 sets of 8 reps',
            'Plank: 2 sets, hold for 20 seconds',
            'Crunches: 2 sets of 15 reps',
          ],
        },
        {
          'date': 'Sunday, 26 October 2025',
          'category': 'Lower & Cardio',
          'exercises': [
            'Bodyweight Squats: 2 sets of 12 reps',
            'Alternating Lunges: 2 sets of 8 reps per leg',
            'Glute Bridges: 2 sets of 15 reps',
          ],
        },
      ],
    },
    {
      'weekTitle': 'Week 2: Building Base',
      'days': [
        {
          'date': 'Tuesday, 28 October 2025',
          'category': 'Upper & Core',
          'exercises': [
            'Push-ups (or Knee Push-ups): 3 sets of 8 reps',
            'Plank: 3 sets, hold for 30 seconds',
            'Crunches: 3 sets of 15 reps',
            'Bird-Dog: 2 sets of 10 reps per side',
          ],
        },
        {
          'date': 'Thursday, 30 October 2025',
          'category': 'Lower & Cardio',
          'exercises': [
            'Bodyweight Squats: 3 sets of 12 reps',
            'Alternating Lunges: 3 sets of 10 reps per leg',
            'Glute Bridges: 3 sets of 15 reps',
            'Calf Raises: 3 sets of 15 reps', // Example for more data
          ],
        },
        {
          'date': 'Saturday, 1 November 2025',
          'category': 'Upper & Core',
          'exercises': [
            'Push-ups (or Knee Push-ups): 3 sets of 8 reps',
            'Plank: 3 sets, hold for 30 seconds',
            'Crunches: 3 sets of 15 reps',
            'Superman: 2 sets of 12 reps', // Example for more data
          ],
        },
      ],
    },
    // Add more weeks/days as needed
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // Set to transparent to show the gradient
      body: Stack(
        children: [
          const _GradientBackground(), // Custom gradient background
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Header(),
                        const SizedBox(height: 28),
                        const _DayCircles(),
                        const SizedBox(height: 24),
                        Text(
                          'Total duration: 4 weeks',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Render the workout plan sections inside a white box
                        Container(
                          margin: const EdgeInsets.only(bottom: 24.0), // Margin from bottom buttons
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _planData.map((weekData) {
                              return _WeekSection(weekData: weekData);
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _ActionButtons(), // Action buttons at the bottom
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Helper Widgets ---

class _GradientBackground extends StatelessWidget {
  const _GradientBackground();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFFFFB3A7), // Top Pink
              Color(0xFFFFE0D9), // Middle Lighter
              Color(0xFFFFCF71), // Bottom Orange
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
      letterSpacing: 1.2,
    );
    return Center(
      child: Text(
        'OVERVIEW OF YOUR PLAN',
        textAlign: TextAlign.center,
        style: titleStyle,
      ),
    );
  }
}

class _DayCircles extends StatelessWidget {
  const _DayCircles();

  final List<String> days = const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
  // Example: 'Mo' and 'Fr' are active (green), others are inactive (grey/white)
  final List<bool> activeDays = const [true, false, true, false, true, false, true];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: List.generate(days.length, (index) {
        return Column(
          children: [
            Text(
              days[index],
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: activeDays[index] ? const Color(0xFF6CC54B) : Colors.white.withOpacity(0.5),
                border: Border.all(
                  color: activeDays[index] ? Colors.transparent : Colors.white.withOpacity(0.8),
                  width: activeDays[index] ? 0 : 2,
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _WeekSection extends StatelessWidget {
  const _WeekSection({required this.weekData});

  final Map<String, dynamic> weekData;

  @override
  Widget build(BuildContext context) {
    final weekTitleStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black, // Changed to black
      decoration: TextDecoration.underline,
      decorationColor: Colors.black, // Changed to black
      decorationThickness: 2,
      height: 1.5,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            weekData['weekTitle'],
            style: weekTitleStyle,
          ),
          const SizedBox(height: 16),
          ..._buildDayDetails(context, weekData['days']),
        ],
      ),
    );
  }

  List<Widget> _buildDayDetails(BuildContext context, List<dynamic> days) {
    return days.map<Widget>((dayData) {
      final dayHeaderStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: Colors.black, // Changed to black
      );
      final exerciseTextStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
        color: Colors.black, // Changed to black
        height: 1.4,
      );

      return Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${dayData['date']} (${dayData['category']}):',
              style: dayHeaderStyle,
            ),
            const SizedBox(height: 8),
            ...dayData['exercises'].map<Widget>((exercise) {
              return Padding(
                padding: const EdgeInsets.only(left: 16.0, bottom: 4.0),
                child: Text(
                  '• $exercise',
                  style: exerciseTextStyle,
                ),
              );
            }).toList(),
          ],
        ),
      );
    }).toList();
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _ActionButton(
            label: 'REPLAN',
            // Sampled colors from the image for REPLAN button
            gradientColors: const [Color(0xFFFC5B6B), Color(0xFFF89052)],
            onPressed: () {
              print('REPLAN tapped');
            },
          ),
          _ActionButton(
            label: 'ACCEPT',
            // Sampled colors from the image for ACCEPT button
            gradientColors: const [Color(0xFF75E966), Color(0xFFC7EF75)],
            onPressed: () {
              print('ACCEPT tapped');
            },
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.gradientColors,
    required this.onPressed,
  });

  final String label;
  final List<Color> gradientColors;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            elevation: 8,
            shadowColor: Colors.black.withOpacity(0.3),
          ),
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradientColors,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Container(
              alignment: Alignment.center,
              constraints: const BoxConstraints(minHeight: 50.0),
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
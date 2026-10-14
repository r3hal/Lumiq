# Focal 2.3.1 / build 21

Codemagic reported an invalid redeclaration of `FeasibleGuidance`, followed by ambiguous type-lookup errors. The frozen Intelligence 2.0 comparison copied the value type into the same app module as the live engine. Because the baseline is included under DEBUG or FOCAL_EVALUATION, this blocked simulator tests and evaluation builds.

Renamed the baseline declaration and all seven references to `BaselineFeasibleGuidance22`. The live engine retains `FeasibleGuidance`. The baseline decision rules, runtime guidance and camera behavior are unchanged.

Added a module-level declaration collision check to the structural validator. It reproduced the exact collision before the fix and passes after the rename. The scan found no additional matching type collisions. The project/data/build-script structural checks pass. The check follows this project's unindented top-level declaration style; it is not a full Swift parser or substitute for Xcode.

The 314 registered native tests remain pending. Xcode is unavailable in this Linux workspace, so a successful native build is not claimed. Start a new Codemagic build from main at the fix commit, using ios-sideload (or ios-evaluation for the developer tool). Restarting the old build at its pinned commit will still compile the old code.

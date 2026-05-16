/// User-facing strings for GS Camera app.
/// All text should be friendly and non-technical (no "azimuth", "bin", etc.).
library;

class AppStrings {
  const AppStrings._();

  /// Mode selection labels
  static const String smartMode = 'Smart';
  static const String roomMode = 'Room';
  static const String objectMode = 'Object';
  static const String sphericalMode = 'Spherical';

  /// Coverage ring labels
  static const String ceilingLabel = 'C';
  static const String floorLabel = 'F';
  static const String coveragePercent = '%';

  /// Guidance hints - these appear in the HUD overlay
  static const String hintCovered = '✓ Covered';
  static const String hintLookLeft = 'Look left';
  static const String hintLookRight = 'Look right';
  static const String hintLookUp = 'Look up';
  static const String hintLookDown = 'Look down';
  static const String hintSlowDown = 'Slow down';
  static const String hintHoldSteady = 'Hold steady';
  static const String hintTooDark = 'Too dark';
  static const String hintBrightLight = 'Bright light';
  static const String hintPointForDetail = 'Point at plain wall for detail';
  static const String hintKeepScanning = 'Keep scanning';
  static const String hintMoveSlowly = 'Move slowly';

  /// Capture button labels
  static const String captureNow = 'Capture now';
  static const String finishScan = 'Finish';
  static const String addMore = 'Add more';

  /// Dialog messages
  static const String dialogFinishTitle = 'Finish scan?';
  static const String dialogFinishContent =
      'We will clean duplicates and export in the background.';
  static const String snackBarNoPhotos = 'No photos captured yet';
  static const String snackBarExportStarting = 'Export starting soon...';

  /// Auto-finish messages
  static String autoFinishCountdown(int seconds) =>
      'Scan complete. Export starts in $seconds';

  /// Status messages
  static const String statusGettingCameraReady = 'Getting camera ready';
  static const String statusReducingDuplicates = 'Reducing duplicate photos';
  static const String statusExporting = 'Exporting...';
  static const String statusFailed = 'Camera failed';

  /// Onboarding step titles
  static const String onboardingStep1Title = 'Point around room';
  static const String onboardingStep2Title = 'Move slowly';
  static const String onboardingStep3Title = 'Watch ring fill';

  /// Onboarding step descriptions
  static const String onboardingStep1Desc =
      'Slowly turn to capture all angles of the room';
  static const String onboardingStep2Desc =
      'Keep movements smooth for best results';
  static const String onboardingStep3Desc =
      'Green segments mean good coverage';

  /// Onboarding button labels
  static const String onboardingNext = 'Next';
  static const String onboardingGotIt = 'Got it!';
  static const String onboardingSkip = 'Skip';

  // ===========================================================================
  // Georgian translations (ქართული)
  // ===========================================================================

  /// Mode selection labels - Georgian
  static const String smartModeKa = 'ჭკვიანი';
  static const String roomModeKa = 'ოთახი';
  static const String objectModeKa = 'ობიექტი';
  static const String sphericalModeKa = 'სფერული';

  /// Coverage ring labels - Georgian
  static const String ceilingLabelKa = 'ჭ';
  static const String floorLabelKa = 'I';

  /// Guidance hints - Georgian
  static const String hintCoveredKa = '✓ დაფარულია';
  static const String hintLookLeftKa = 'იყურე მარცხნივ';
  static const String hintLookRightKa = 'იყურე მარჯვნივ';
  static const String hintLookUpKa = 'იყურე ზევით';
  static const String hintLookDownKa = 'იყურე ქვემოთ';
  static const String hintSlowDownKa = 'უფრო ნელა';
  static const String hintHoldSteadyKa = 'მყარად დაიჭირე';
  static const String hintTooDarkKa = 'ძალიან ბნელია';
  static const String hintBrightLightKa = 'ძალიან ნათელია';
  static const String hintPointForDetailKa = 'მიმართე კედელზე დეტალებისთვის';
  static const String hintKeepScanningKa = 'განაგრძე სკანირება';
  static const String hintMoveSlowlyKa = 'იმოძრავე ნელა';

  /// Capture button labels - Georgian
  static const String captureNowKa = 'გადაღება';
  static const String finishScanKa = 'დასრულება';
  static const String addMoreKa = 'დამატება';

  /// Dialog messages - Georgian
  static const String dialogFinishTitleKa = 'დავასრულოთ სკანირება?';
  static const String dialogFinishContentKa =
      'ჩვენ წავშლით დუბლიკატებს და ექსპორტი ფონურად მოხდება.';
  static const String snackBarNoPhotosKa = 'ჯერ არცერთი ფოტო არ გადაგიღიათ';
  static const String snackBarExportStartingKa = 'ექსპორტი მალე დაიწყება...';

  /// Auto-finish messages - Georgian
  static String autoFinishCountdownKa(int seconds) =>
      'სკანირება დასრულდა. ექსპორტი დაიწყება $seconds წამში';

  /// Status messages - Georgian
  static const String statusGettingCameraReadyKa = 'კამერის მომზადება';
  static const String statusReducingDuplicatesKa = 'დუბლიკატების შემცირება';
  static const String statusExportingKa = 'ექსპორტი მიმდინარეობს...';
  static const String statusFailedKa = 'კამერის შეცდომა';

  /// Onboarding step titles - Georgian
  static const String onboardingStep1TitleKa = 'მიმართეთ ოთახში';
  static const String onboardingStep2TitleKa = 'იმოძრავეთ ნელა';
  static const String onboardingStep3TitleKa = 'დააკვირდით რგოლს';

  /// Onboarding step descriptions - Georgian
  static const String onboardingStep1DescKa =
      'ნელა შეატრიალეთ კამერა ოთახის ყველა კუთხის გადასაღებად';
  static const String onboardingStep2DescKa =
      'შეინარჩუნეთ მოძრაობები გლუვი საუკეთესო შედეგებისთვის';
  static const String onboardingStep3DescKa =
      'მწვანე სეგმენტები ნიშნავს კარგ დაფარვას';

  /// Onboarding button labels - Georgian
  static const String onboardingNextKa = 'შემდეგი';
  static const String onboardingGotItKa = 'გასაგებია!';
  static const String onboardingSkipKa = 'გამოტოვება';

  /// Helper to get localized string based on locale code
  static String getMode(String mode, String localeCode) {
    if (localeCode.startsWith('ka')) {
      return switch (mode) {
        'Smart' => smartModeKa,
        'Room' => roomModeKa,
        'Object' => objectModeKa,
        'Spherical' => sphericalModeKa,
        _ => mode,
      };
    }
    return mode;
  }

  static String getGuidance(String guidance, String localeCode) {
    if (localeCode.startsWith('ka')) {
      return switch (guidance) {
        'Covered' => hintCoveredKa,
        'Look left' => hintLookLeftKa,
        'Look right' => hintLookRightKa,
        'Look up' => hintLookUpKa,
        'Look down' => hintLookDownKa,
        'Slow down' => hintSlowDownKa,
        'Hold steady' => hintHoldSteadyKa,
        'Too dark' => hintTooDarkKa,
        'Bright light' => hintBrightLightKa,
        'Point at plain wall for detail' => hintPointForDetailKa,
        'Keep scanning' => hintKeepScanningKa,
        'Move slowly' => hintMoveSlowlyKa,
        _ => guidance,
      };
    }
    return guidance;
  }
}

final class ReaderCapabilities {
  const ReaderCapabilities({
    this.supportsPagination = false,
    this.supportsScrolling = false,
    this.supportsTextCustomization = false,
    this.supportsColumnMode = false,
    this.supportsPageTurnAnimation = false,
  });

  final bool supportsPagination;
  final bool supportsScrolling;
  final bool supportsTextCustomization;
  final bool supportsColumnMode;
  final bool supportsPageTurnAnimation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderCapabilities &&
          supportsPagination == other.supportsPagination &&
          supportsScrolling == other.supportsScrolling &&
          supportsTextCustomization == other.supportsTextCustomization &&
          supportsColumnMode == other.supportsColumnMode &&
          supportsPageTurnAnimation == other.supportsPageTurnAnimation;

  @override
  int get hashCode => Object.hash(
    supportsPagination,
    supportsScrolling,
    supportsTextCustomization,
    supportsColumnMode,
    supportsPageTurnAnimation,
  );
}

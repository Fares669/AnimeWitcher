// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'details_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(DetailsController)
final detailsControllerProvider = DetailsControllerFamily._();

final class DetailsControllerProvider
    extends $NotifierProvider<DetailsController, DetailsState> {
  DetailsControllerProvider._({
    required DetailsControllerFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'detailsControllerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$detailsControllerHash();

  @override
  String toString() {
    return r'detailsControllerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  DetailsController create() => DetailsController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DetailsState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DetailsState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DetailsControllerProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$detailsControllerHash() => r'7b704e48a89e84f636d4c3c5ba1935891f677eb4';

final class DetailsControllerFamily extends $Family
    with
        $ClassFamilyOverride<
          DetailsController,
          DetailsState,
          DetailsState,
          DetailsState,
          String
        > {
  DetailsControllerFamily._()
    : super(
        retry: null,
        name: r'detailsControllerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DetailsControllerProvider call(String itemUrl) =>
      DetailsControllerProvider._(argument: itemUrl, from: this);

  @override
  String toString() => r'detailsControllerProvider';
}

abstract class _$DetailsController extends $Notifier<DetailsState> {
  late final _$args = ref.$arg as String;
  String get itemUrl => _$args;

  DetailsState build(String itemUrl);
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<DetailsState, DetailsState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<DetailsState, DetailsState>,
              DetailsState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, () => build(_$args));
  }
}

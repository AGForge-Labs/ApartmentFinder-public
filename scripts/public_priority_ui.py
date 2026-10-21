"""The same three-case warm control on frozen EA's public source."""
import re

WARM = (
    'ApartmentFinderUITests/CommunityMapControlsTests/testLyricAndTrendShowTheirCommunityAreasWithoutInventingDoors',
    'ApartmentFinderUITests/CommunityMapControlsTests/testPausedControlsStayCompactAndKeepTheirActions',
    'ApartmentFinderUITests/MapAppearanceTests/testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch',
)
GEOGRAPHY = (
    'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport',
    'ApartmentFinderUITests/OnTracFlowTests/testZIPPreviewCancellationEmptyDayAndApartmentNavigation',
    'ApartmentFinderUITests/Reviewed89123GeographyUITests/testHistoricalAliasAndFloorOnlyReferenceDoNotInventATowerOrDoor',
    'ApartmentFinderUITests/Reviewed89123GeographyUITests/testPebbleUsesOneApproximateMarkerPerBuildingAndRetainsUnitFloorSelection',
    'ApartmentFinderUITests/Reviewed89123GeographyUITests/testStackedSourceUnitFloorsAndRecoveredSummerLabelsRemainUnverified',
)


def selected_cases(scope, profile):
    from iterate import test_ids
    assert scope == 'map-style-warm-diagnostics'
    # Preserve EA's original public profile; its focused community/style methods
    # existed outside that older two-case UI selection.
    assert (len(profile['core']), len(profile['native']), len(profile['ui'])) == (123, 71, 2)
    assert set(profile['ui']) == set(GEOGRAPHY[:2])
    assert all(identity.removeprefix('ApartmentFinderUITests/') in test_ids('.', 'UITests') for identity in WARM)
    return {'native': [], 'ui': list(WARM)}


def verify_warm_order(body):
    observed = re.findall(r"Test Case '-\[(?:ApartmentFinderUITests\.)?([A-Za-z0-9_]+) (test[A-Za-z0-9_]+)\]' started\.", body)
    expected = [tuple(identity.split('/')[1:]) for identity in WARM]
    assert observed == expected, 'The three-case warm sequence did not execute in the required order'
    print('MAP-STYLE-WARM-ORDER communityLocation,compactControls,mapAppearance')

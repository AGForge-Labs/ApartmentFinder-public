"""Fixed diagnostic partitions of the unchanged eight public UI cases."""
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
    assert len(profile['ui']) == 8 and set(profile['ui']) == set(WARM + GEOGRAPHY)
    cases = {'map-style-warm-diagnostics': WARM, 'reviewed-geography-regression': GEOGRAPHY,
             'reviewed-geography-only-regression': GEOGRAPHY[2:]}[scope]
    return {'native': [], 'ui': list(cases)}


def verify_warm_order(body):
    observed = re.findall(r"Test Case '-\[(?:ApartmentFinderUITests\.)?([A-Za-z0-9_]+) (test[A-Za-z0-9_]+)\]' started\.", body)
    expected = [tuple(identity.split('/')[1:]) for identity in WARM]
    assert observed == expected, 'The three-case warm sequence did not execute in the required order'
    print('MAP-STYLE-WARM-ORDER communityLocation,compactControls,mapAppearance')

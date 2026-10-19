"""Retrieve only public physical site/unit geography from Clark County GIS.

No owner, tax, sale, or other household fields are requested or retained.
The annotation polygons are text extents, not unit footprints or doorways.
"""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[2] / "research" / "geography"
BASE = "https://maps.clarkcountynv.gov/arcgis/rest/services/"
ANNOTATION_URL = BASE + "GISMO/AssessorAnno/MapServer/0/query?" + urlencode({
    "f": "pjson",
    "where": "AnnotationClassID IN (17,21)",
    "geometry": "-115.2516,36.0668,-115.2480,36.0703",
    "geometryType": "esriGeometryEnvelope",
    "inSR": "4326",
    "spatialRel": "esriSpatialRelIntersects",
    "outFields": "OBJECTID,FeatureID,AnnotationClassID,TextString,Angle",
    "outSR": "4326",
    "returnGeometry": "true",
    "resultRecordCount": "3000",
})
DIRECTORY_URL = BASE + "GISMO/Address/MapServer/2/query?" + urlencode({
    "f": "pjson",
    "where": "Parcel LIKE '17603510%'",
    "outFields": "Parcel,APN,strno,strdir,strname,strtype,strunit,subname,LEGAL_DESCR3,ADFILE,ADPAGE",
    "outSR": "4326",
    "returnGeometry": "true",
    "resultRecordCount": "1000",
})


def retrieve(url):
    with urlopen(url, timeout=30) as response:
        payload = json.load(response)
    if payload.get("error") or payload.get("exceededTransferLimit"):
        raise ValueError(f"Incomplete county response: {payload}")
    return payload, datetime.now(timezone.utc).isoformat(timespec="seconds")


def main():
    with ThreadPoolExecutor(max_workers=2) as pool:
        annotation_future = pool.submit(retrieve, ANNOTATION_URL)
        directory_future = pool.submit(retrieve, DIRECTORY_URL)
        annotations, annotation_time = annotation_future.result()
        directory, directory_time = directory_future.result()
    wrapper = {
        "communityID": "tuscano",
        "communityName": "Tuscano Condominiums",
        "address": "7255 W Sunset Rd, Las Vegas, NV 89113",
        "retrievedAt": max(annotation_time, directory_time),
        "annotationRetrievedAt": annotation_time,
        "directoryRetrievedAt": directory_time,
        "annotationURL": ANNOTATION_URL,
        "unitDirectoryURL": DIRECTORY_URL,
        "sourceLastUpdatedAt": None,
        "sourceDateNote": "The queried county layers expose no last-edited or effective date. RetrievedAt records retrieval, not source currency.",
        "coordinateReferenceSystem": "EPSG:4326",
        "annotationGeometryMeaning": "Geographic bounds of county map-label text; not a unit boundary or surveyed doorway.",
        "directoryGeometryMeaning": "County condo parcel geometry repeats across units in each building; usable as a building envelope, not a unit footprint.",
        "positionInterpretation": "A source-mapped unit-position estimate is the center of its exact matching label extent, joined to county strunit and LEGAL_DESCR3. Door position and access path remain unverified.",
        "horizontalAccuracyMeters": None,
        "floorInferenceAllowed": False,
        "annotations": annotations,
        "directory": directory,
    }
    output = ROOT / "tuscano-county-unit-labels.json"
    output.write_text(json.dumps(wrapper, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"path": str(output), "retrievedAt": wrapper["retrievedAt"], "annotations": len(annotations["features"]), "directoryUnits": len(directory["features"])}))


if __name__ == "__main__":
    main()

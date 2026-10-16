"""
qos_map.py -- service category -> QoS class. A DRAFT for review, not a decision.

The TCN can be trained on three label sets, finest to coarsest:
  APP       180 services (servicemap.csv "Tag")
  CATEGORY   23 service categories
  QOS         5 QoS classes, defined here

The hardware does not care which: only the size of the output layer changes,
and the class -> treatment policy is a P4 table the LLM writes. Training on QOS
directly is the first experiment because it is the decision the data plane
actually needs.

Caveat (see datasets/cesnet/DATA_NOTES.md): these are TLS-over-TCP flows. For
video calls the real-time media normally runs over UDP, so "Videoconferencing"
TLS flows are mostly signalling.
"""
import csv
import os

QOS_CLASSES = ["realtime", "streaming", "interactive", "bulk", "background"]

CATEGORY_TO_QOS = {
    "Videoconferencing":     "realtime",
    "Remote desktop":        "realtime",
    "Games":                 "realtime",
    "Instant messaging":     "realtime",
    "Virtual assistant":     "realtime",
    "Media":                 "streaming",
    "Music":                 "streaming",
    "Social":                "interactive",
    "Search":                "interactive",
    "Mail":                  "interactive",
    "Internet banking":      "interactive",
    "Information systems":   "interactive",
    "Authentication":        "interactive",
    "Weather":               "interactive",
    "Location":              "interactive",
    "Other services":        "interactive",
    "Other APIs":            "interactive",
    "Software updates":      "bulk",
    "File sharing":          "bulk",
    "Antivirus":             "bulk",
    "Advertising":           "background",
    "Analytics & Telemetry": "background",
    "Notifications":         "background",
}


def load_label_maps(servicemap_csv):
    """Stable integer ids: apps and categories sorted by name."""
    rows = list(csv.DictReader(open(servicemap_csv)))
    apps = sorted(r["Tag"] for r in rows)
    cats = sorted({r["Service Category"] for r in rows})
    missing = set(cats) - set(CATEGORY_TO_QOS)
    if missing:
        raise ValueError(f"categories without a QoS class: {sorted(missing)}")
    return {
        "apps": apps,
        "app_id": {a: i for i, a in enumerate(apps)},
        "categories": cats,
        "cat_id": {c: i for i, c in enumerate(cats)},
        "cat_to_qos": [QOS_CLASSES.index(CATEGORY_TO_QOS[c]) for c in cats],
    }


def default_servicemap():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", "datasets", "cesnet", "tls-year22", "servicemap.csv")

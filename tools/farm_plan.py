#!/usr/bin/env python3
"""Farm plan: the data model shared by the designer app and the game.

The plan is the authored answer to what the terrain shader currently guesses with a
hash. It is deliberately a plain, hand-editable JSON document — the designer app is a
convenience, not the format's owner.

Coordinates. The plan covers a fixed square centred on the world origin, sized so it is
inscribed in the game's flat farm basin: the basin has radius ~380, and a 512x512 square
reaches 362 at its corners, so every cell is guaranteed to be on flat ground. Cells are
2 world units, giving a 256x256 grid — fine enough for a 4-unit road, coarse enough that
the whole grid is 64 KB and repaints instantly.

Cells store a ZONE ID, not a colour or a material. Zones carry the meaning (ground, what
lives there, whether it is fenced), so retyping a zone repaints every cell that belongs
to it. Zone 0 is reserved: "not authored", i.e. leave it to the terrain's own rules.

Rows are run-length encoded as "id:count,id:count". That keeps the file diffable — a
change to one pen touches a handful of lines — without storing 65k integers.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from typing import Any

import numpy as np

VERSION = 1

# Must match scripts/farm_plan.gd.
CELL_SIZE = 2.0
GRID = 256
EXTENT = CELL_SIZE * GRID          # 512 world units
ORIGIN = -EXTENT / 2.0             # -256: the grid's top-left corner in world space

NATURAL_ZONE = 0

# Ground types. The index is the layer in the game's ground Texture2DArray, so the order
# here is load-bearing and must match scripts/terrain_textures.gd. Append only: these
# integers are already written into farm/plan.json, so reordering silently repaints every
# authored zone.
#
# "mud" is paintable here, but an animal zone also gets it automatically around its gates
# and troughs — see FarmPlan.trample_texture in the game. Painting it is for a pen that is
# a mud bath end to end.
GROUND_TYPES = ["pasture", "dirt", "road", "crop", "mud"]

# Species the game can spawn into a zone. None means the area is just ground.
CONTENTS = ["none", "cow", "horse"]

STRUCTURE_TYPES = [
    # The yard.
    "house", "barn", "shed", "silo", "coop", "well",
    # Storage and grain.
    "granary", "corn_crib", "grain_bin",
    # Machinery and livestock.
    "machine_shed", "stable", "pigsty",
    # Water and wind. Tall enough to read from across the basin, like the silo.
    "windmill", "water_tower",
    # Yard clutter: small props that fill dead space and make the farm look worked.
    "trough", "haystack", "hay_feeder", "compost_heap", "fuel_tank", "log_pile",
]

# Editor swatches. Not what the game renders — just what reads clearly top-down.
GROUND_COLOURS = {
    "pasture": (104, 152, 68),
    "dirt": (140, 100, 62),
    "road": (150, 148, 140),
    "crop": (160, 128, 70),
    "mud": (74, 58, 46),
}
# Deliberately desaturated and dark: unpainted ground must not be mistakable for a
# painted pasture zone, or you cannot see what you have actually authored.
NATURAL_COLOUR = (46, 58, 40)


@dataclass
class Zone:
    id: int
    name: str
    ground: str = "pasture"
    contents: str = "none"
    count: int = 0
    fenced: bool = False

    def colour(self) -> tuple[int, int, int]:
        return GROUND_COLOURS.get(self.ground, NATURAL_COLOUR)


@dataclass
class Structure:
    type: str
    x: float
    z: float
    yaw: float = 0.0


@dataclass
class FarmPlan:
    zones: list[Zone] = field(default_factory=list)
    structures: list[Structure] = field(default_factory=list)
    cells: np.ndarray = field(default_factory=lambda: np.zeros((GRID, GRID), np.uint8))

    # ---- zone helpers -------------------------------------------------------

    def zone(self, zone_id: int) -> Zone | None:
        for z in self.zones:
            if z.id == zone_id:
                return z
        return None

    def next_zone_id(self) -> int:
        used = {z.id for z in self.zones}
        for candidate in range(1, 256):
            if candidate not in used:
                return candidate
        raise ValueError("all 255 zone ids are in use")

    # ---- coordinates --------------------------------------------------------

    @staticmethod
    def cell_to_world(col: int, row: int) -> tuple[float, float]:
        """Centre of a cell, in world units."""
        return (ORIGIN + (col + 0.5) * CELL_SIZE, ORIGIN + (row + 0.5) * CELL_SIZE)

    @staticmethod
    def world_to_cell(x: float, z: float) -> tuple[int, int]:
        return (int((x - ORIGIN) / CELL_SIZE), int((z - ORIGIN) / CELL_SIZE))

    # ---- serialisation ------------------------------------------------------

    def to_json(self) -> str:
        doc: dict[str, Any] = {
            "version": VERSION,
            "world": {"cell_size": CELL_SIZE, "grid": GRID, "origin": ORIGIN},
            "zones": [asdict(z) for z in self.zones],
            "structures": [asdict(s) for s in self.structures],
            "cells": [_encode_row(self.cells[r]) for r in range(GRID)],
        }
        return json.dumps(doc, indent=1)

    @classmethod
    def from_json(cls, text: str) -> "FarmPlan":
        doc = json.loads(text)
        if doc.get("version") != VERSION:
            raise ValueError(f"plan version {doc.get('version')!r}, expected {VERSION}")
        w = doc["world"]
        if w["grid"] != GRID or abs(w["cell_size"] - CELL_SIZE) > 1e-6:
            raise ValueError(
                f"plan grid {w['grid']}@{w['cell_size']} does not match this build "
                f"({GRID}@{CELL_SIZE}); the game and the designer must agree"
            )
        plan = cls(
            zones=[Zone(**z) for z in doc["zones"]],
            structures=[Structure(**s) for s in doc["structures"]],
            cells=np.zeros((GRID, GRID), np.uint8),
        )
        for r, row in enumerate(doc["cells"]):
            plan.cells[r] = _decode_row(row)
        return plan

    # ---- derived ------------------------------------------------------------

    def ground_layer_map(self) -> np.ndarray:
        """Cells -> ground layer index, which is what the shader actually samples.

        Zone 0 and any dangling zone id fall back to pasture, so a half-deleted plan
        renders as grass rather than as garbage.
        """
        lut = np.zeros(256, np.uint8)
        for z in self.zones:
            if z.ground in GROUND_TYPES:
                lut[z.id] = GROUND_TYPES.index(z.ground)
        return lut[self.cells]

    def zone_cell_counts(self) -> dict[int, int]:
        ids, counts = np.unique(self.cells, return_counts=True)
        return {int(i): int(c) for i, c in zip(ids, counts)}


def _encode_row(row: np.ndarray) -> str:
    parts: list[str] = []
    value = int(row[0])
    run = 0
    for cell in row:
        cell = int(cell)
        if cell == value:
            run += 1
        else:
            parts.append(f"{value}:{run}")
            value, run = cell, 1
    parts.append(f"{value}:{run}")
    return ",".join(parts)


def _decode_row(text: str) -> np.ndarray:
    out = np.zeros(GRID, np.uint8)
    at = 0
    for part in text.split(","):
        value, _, run = part.partition(":")
        n = int(run)
        out[at:at + n] = int(value)
        at += n
    if at != GRID:
        raise ValueError(f"row decodes to {at} cells, expected {GRID}")
    return out


def default_plan() -> FarmPlan:
    """A small starter farm, so a fresh checkout has something to look at."""
    plan = FarmPlan()
    plan.zones = [
        Zone(1, "Yard", ground="dirt"),
        Zone(2, "Cow Pen", ground="dirt", contents="cow", count=30, fenced=True),
        Zone(3, "Horse Paddock", ground="pasture", contents="horse", count=22, fenced=True),
        Zone(4, "Main Road", ground="road"),
        Zone(5, "Wheat Field", ground="crop"),
        Zone(6, "West Pasture", ground="pasture", contents="cow", count=24, fenced=True),
    ]

    def rect(zone_id: int, x0: float, z0: float, x1: float, z1: float) -> None:
        c0, r0 = FarmPlan.world_to_cell(x0, z0)
        c1, r1 = FarmPlan.world_to_cell(x1, z1)
        plan.cells[r0:r1, c0:c1] = zone_id

    rect(4, -6, -240, 6, 240)      # road running north-south through the farm
    rect(1, 6, -40, 60, 30)        # yard east of the road
    rect(2, 66, -40, 130, 10)      # cow pen
    rect(3, -120, -60, -12, 40)    # horse paddock west of the road
    rect(5, 6, 40, 120, 150)       # wheat field
    rect(6, -230, 60, -30, 210)    # big grazing pasture, south-west
    # The yard reads as a farm because of where things sit relative to each other, not
    # because of how many things there are: house and barn face each other across the
    # track, grain stands together at the north end, machinery keeps its own corner, and
    # the tall pair (silo, water tower) are split apart so they read as two landmarks
    # rather than one clump.
    plan.structures = [
        # House and barn either side of the yard, both gable-on to the road.
        Structure("house", 18.0, -30.0, 90.0),
        Structure("barn", 34.0, -18.0, 0.0),
        Structure("well", 24.0, -38.0, 0.0),
        Structure("log_pile", 12.0, -22.0, 0.0),
        # Grain: the old silo and the new bin next to each other, stores behind them.
        Structure("silo", 52.0, -32.0, 0.0),
        Structure("grain_bin", 44.0, -34.0, 0.0),
        Structure("granary", 52.0, -22.0, 90.0),
        Structure("corn_crib", 52.0, -12.0, 90.0),
        # Machinery, off the yard's south-east corner where a tractor can swing out.
        Structure("machine_shed", 40.0, 8.0, 180.0),
        Structure("fuel_tank", 30.0, 6.0, 0.0),
        Structure("shed", -30.0, -46.0, 180.0),
        # Livestock, near the pens they serve. The stable stays on the YARD side of the
        # road rather than in the paddock: a structure inside a fenced zone gets no road
        # spur (FarmRoads._destinations), and a stable you cannot drive to is a folly.
        Structure("stable", 14.0, -6.0, 90.0),
        Structure("pigsty", 20.0, 20.0, 0.0),
        Structure("coop", 12.0, 14.0, 90.0),
        # The cow pen's furniture. Both are trample sources, so the ground around them
        # goes to mud — see FarmPlan.TRAMPLE_STRUCTURES in the game.
        Structure("trough", 80.0, -14.0, 0.0),
        Structure("hay_feeder", 92.0, -26.0, 0.0),
        # The horse paddock's.
        Structure("hay_feeder", -40.0, -30.0, 0.0),
        # Muck and fodder, downwind at the yard's edge.
        Structure("compost_heap", 44.0, 24.0, 0.0),
        Structure("haystack", 34.0, 22.0, 0.0),
        # The two landmarks, deliberately far apart and far from the silo. Both stand on
        # open ground between the pens, not inside one, so a track reaches each.
        Structure("water_tower", 66.0, 20.0, 0.0),
        Structure("windmill", -60.0, 52.0, 0.0),
    ]
    return plan


if __name__ == "__main__":
    p = default_plan()
    text = p.to_json()
    back = FarmPlan.from_json(text)
    assert (back.cells == p.cells).all(), "round-trip changed the cells"
    print(f"round-trip ok: {len(text)} bytes, {len(p.zones)} zones, "
          f"{len(p.structures)} structures")
    print("cells per zone:", p.zone_cell_counts())

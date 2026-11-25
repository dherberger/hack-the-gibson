#ifndef GIBSON_CITY_H_
#define GIBSON_CITY_H_

/* The city's layout, in its own coordinates (the flight path's space, see
 * GibsonSCNScene.h -worldRoot). Mirrors the constants in GibsonSCNScene.mm's
 * -addTowers: towers sit on a 30-unit grid, 60 x 60.
 *
 *   tower centres:   x = 15 + 30i,  z = 30j
 *   streets along z: x = 30i        (between tower columns)
 *   streets along x: z = 15 + 30j   (between tower rows)
 *   corners:         (30i, 15 + 30j)
 */
#define GIBSON_CITY_BLOCK 30.f
/* Half the tower's width: the 9.125-unit mesh scaled by TOWER_FOOTPRINT 1.6. */
#define GIBSON_CITY_TOWER_HALF 7.3f
/* Tower height: the mesh's 34.38 units scaled by TOWER_HEIGHT 1.265. */
#define GIBSON_CITY_TOWER_TOP 43.5f
/* Keep to corners well inside the 60 x 60 grid (about +-900). */
#define GIBSON_CITY_LIMIT 840.f

#endif

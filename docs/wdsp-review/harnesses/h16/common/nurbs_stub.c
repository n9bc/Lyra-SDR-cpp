/* Stub: CFC uses gdeg=edeg=0 by default, so BuildSpline is never reached. */
#include <stdlib.h>
#include "nurbs.h"
NURBS create_nurbs(int n, int p, int r, int umethod, int upts,
	int max_cp, int max_deg, int max_upts, int max_fpts)
{
	NURBS a = (NURBS)calloc(1, sizeof(nurbs));
	a->n = n; a->p = p; a->r = r; a->umethod = umethod; a->upts = upts;
	a->max_cp = max_cp; a->max_p = max_deg; a->max_upts = max_upts; a->max_fpts = max_fpts;
	return a;
}
void destroy_nurbs(NURBS a) { free(a); }
void BuildSpline(int n, int p, int r, int umethod, double* U, double* CP, double* W,
	int upts, double* Xs, double* Ys, double* Uout, int fpts, double* Xf, double* Yf)
{ abort(); }

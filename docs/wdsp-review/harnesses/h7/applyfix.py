import sys
D=sys.argv[1]
p=D+'/nobII.h'; s=open(p).read()
s=s.replace("\tint overflow;\n","\tint overflow;\n\tint seeded;\t\t\t\t\t// FIX: avg seeded from data\n\tint consec;\t\t\t\t\t// FIX: consecutive flagged samples\n\tint guardK;\t\t\t\t\t// FIX: level-step guard length\n\tdouble shadow;\t\t\t\t// FIX: uncensored mean for level-step guard\n",1)
assert 'seeded' in s
open(p,'w').write(s)
p=D+'/nobII.c'; s=open(p).read()
o="    a->avg = 1.0;\n"; assert o in s
s=s.replace(o,"    a->avg = 1.0;\n    a->seeded = 0;\n    a->consec = 0;\n    a->shadow = 1.0;\n    a->guardK = (int)(0.005 * a->samplerate);\n",1)
old="""			a->avg = a->backmult * a->avg + a->ombackmult * mag;
			if (mag > (a->avg * a->threshold))
				a->imp[a->in_idx] = 1;
			else
				a->imp[a->in_idx] = 0;
"""
new="""			if (mag == 0.0)
				a->imp[a->in_idx] = 0;		// FIX: hold avg through exact-zero input
			else
			{
				int flag;
				a->shadow = a->backmult * a->shadow + a->ombackmult * mag;
				flag = (mag > (a->avg * a->threshold));
#if FIX_CLIP
				a->avg = a->backmult * a->avg + a->ombackmult * fmin (mag, a->threshold * a->avg);
#else
				if (!flag) a->avg = a->backmult * a->avg + a->ombackmult * mag;	// FIX: censored update
#endif
				if (flag) a->consec++; else a->consec = 0;
				if (a->consec > a->guardK)		// FIX: level-step guard
				{
					a->avg = a->shadow;
					a->consec = 0;
				}
				a->imp[a->in_idx] = flag;
			}
"""
assert old in s; s=s.replace(old,new,1)
old2="""    if (a->run)
	{
		for (i = 0; i < a->buffsize; i++)"""
new2="""    if (a->run)
	{
		if (!a->seeded)		// FIX: seed avg from first non-silent block's median |x|
		{
			int n = 0;
			double *m = (double *)malloc (a->buffsize * sizeof (double));
			for (i = 0; i < a->buffsize; i++)
			{
				double v = sqrt (a->in[2 * i] * a->in[2 * i] + a->in[2 * i + 1] * a->in[2 * i + 1]);
				if (v > 0.0) m[n++] = v;
			}
			if (n > a->buffsize / 2)
			{
				int c, d; double t;
				for (c = 1; c < n; c++) { t = m[c]; d = c - 1; while (d >= 0 && m[d] > t) { m[d + 1] = m[d]; d--; } m[d + 1] = t; }
				a->avg = a->shadow = 1.0645 * m[n / 2];	// Rayleigh mean/median
				a->seeded = 1;
			}
			free (m);
		}
		for (i = 0; i < a->buffsize; i++)"""
assert old2 in s; s=s.replace(old2,new2,1)
open(p,'w').write(s)

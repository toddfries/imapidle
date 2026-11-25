#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <asr.h>
#include <arpa/nameser.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static void
asr_set(HV *h, const char *k, SV *v)
{
	hv_store(h, k, strlen(k), v, 0);
}

static struct asr_query *
asr_ptr(SV *self)
{
	SV *rv;

	if (!SvROK(self))
		croak("IMAPIDLE::Asr method called on a non-object");
	rv = SvRV(self);
	if (!SvIOK(rv))
		croak("IMAPIDLE::Asr method called on a non-object");
	return INT2PTR(struct asr_query *, SvIV(rv));
}

MODULE = IMAPIDLE::Asr  PACKAGE = IMAPIDLE::Asr

PROTOTYPES: DISABLE

SV *
search(const char *class, const char *name, const char *type)
CODE:
	struct asr_query *q;
	int t;
	SV *rv;

	t = (type != NULL && strcmp(type, "AAAA") == 0) ? T_AAAA : T_A;
	q = res_search_async(name, C_IN, t, NULL);
	if (q == NULL)
		croak("res_search_async: %s", strerror(errno));
	rv = newSV(0);
	sv_setref_pv(rv, class, (void *)q);
	RETVAL = rv;
OUTPUT:
	RETVAL

SV *
run(SV *self)
CODE:
	struct asr_query *q;
	struct asr_result r;
	HV *h;
	int rc;

	q = asr_ptr(self);
	if (q == NULL)
		croak("asr query already finished");
	memset(&r, 0, sizeof(r));
	rc = asr_run(q, &r);
	h = newHV();
	if (rc == 0) {
		asr_set(h, "done", newSViv(0));
		asr_set(h, "cond", newSVpv(
		    r.ar_cond == ASR_WANT_WRITE ? "write" : "read", 0));
		asr_set(h, "fd", newSViv(r.ar_fd));
		asr_set(h, "timeout_ms", newSViv(r.ar_timeout));
	} else {
		/* The completing asr_run frees the query. Do not abort it. */
		SvIV_set(SvRV(self), 0);
		asr_set(h, "done", newSViv(1));
		asr_set(h, "errno", newSViv(r.ar_errno));
		if (r.ar_data != NULL) {
			asr_set(h, "rcode", newSViv(r.ar_rcode));
			if (r.ar_datalen > 0)
				asr_set(h, "packet",
				    newSVpvn(r.ar_data, r.ar_datalen));
			free(r.ar_data);
		} else {
			asr_set(h, "rcode", newSViv(-1));
			asr_set(h, "timeout", newSViv(1));
		}
	}
	RETVAL = newRV_noinc((SV *)h);
OUTPUT:
	RETVAL

void
DESTROY(SV *self)
CODE:
	if (SvROK(self) && SvIOK(SvRV(self))) {
		struct asr_query *q = INT2PTR(struct asr_query *,
		    SvIV(SvRV(self)));
		if (q != NULL) {
			asr_abort(q);
			SvIV_set(SvRV(self), 0);
		}
	}

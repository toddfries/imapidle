# libc asr only.
CC?= cc
CFLAGS += -O2 -fPIC -Wall
PERLINC!= perl -MConfig -e 'print "-I$$Config{archlib}/CORE $$Config{ccflags}"'
TYPEMAP!= perl -MConfig -e 'print "$$Config{privlib}/ExtUtils/typemap"'

all: ../../blib/auto/IMAPIDLE/Asr/Asr.so

Asr.c: Asr.xs
	xsubpp -typemap ${TYPEMAP} Asr.xs > Asr.c.tmp && mv Asr.c.tmp Asr.c

Asr.o: Asr.c
	${CC} ${CFLAGS} ${PERLINC} -c Asr.c

../../blib/auto/IMAPIDLE/Asr/Asr.so: Asr.o
	mkdir -p ../../blib/auto/IMAPIDLE/Asr
	# Rename into place so a running process keeps the old inode.
	${CC} -shared -fPIC -o $@.new Asr.o
	mv $@.new $@

clean:
	rm -f Asr.c Asr.o ../../blib/auto/IMAPIDLE/Asr/Asr.so

.PHONY: all clean

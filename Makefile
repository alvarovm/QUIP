# H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
# H0 X
# H0 X   libAtoms+QUIP: atomistic simulation library
# H0 X
# H0 X   Portions of this code were written by
# H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
# H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
# H0 X
# H0 X   Copyright 2006-2010.
# H0 X
# H0 X   These portions of the source code are released under the GNU General
# H0 X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
# H0 X
# H0 X   If you would like to license the source code under different terms,
# H0 X   please contact Gabor Csanyi, gabor@csanyi.net
# H0 X
# H0 X   Portions of this code were written by Noam Bernstein as part of
# H0 X   his employment for the U.S. Government, and are not subject
# H0 X   to copyright in the USA.
# H0 X
# H0 X
# H0 X   When using this software, please cite the following reference:
# H0 X
# H0 X   http://www.libatoms.org
# H0 X
# H0 X  Additional contributions by
# H0 X    Alessio Comisso, Chiara Gattinoni, and Gianpietro Moras
# H0 X
# H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

ifneq (${QUIP_ARCH},)
	export BUILDDIR=build.${QUIP_ARCH}
	export QUIP_ARCH
	include ${BUILDDIR}/Makefile.inc
	include Makefile.rules
	include Makefile.config
	include Makefiles/Makefile.${QUIP_ARCH}
else
	BUILDDIR=crap
endif


ifeq (${HAVE_GP},1)
MODULES = libAtoms gp QUIP_Core QUIP_Utils GAProgs QUIP_Programs # Tests
else
MODULES = libAtoms QUIP_Core QUIP_Utils QUIP_Programs # Tests
endif
FOX = FoX-4.0.3
EXTRA_CLEAN_DIRS = Tools/quippy

all: ${MODULES}

.PHONY: arch ${MODULES} doc

arch: 
ifeq (${QUIP_ARCH},)
	@echo
	@echo "You need to define the architecture using the QUIP_ARCH variable"
	@echo
	@exit 1
endif

${FOX}: ${FOX}/objs.${QUIP_ARCH}/lib/libFoX_common.a
${FOX}/objs.${QUIP_ARCH}/lib/libFoX_common.a:
	make -C ${FOX} -I${PWD} -I${PWD}/Makefiles -I${PWD}/${BUILDDIR} -f Makefile.QUIP 


${MODULES}: ${BUILDDIR}
	ln -sf ${PWD}/$@/Makefile ${BUILDDIR}/Makefile
	${MAKE} -C ${BUILDDIR} VPATH=${PWD}/$@ -I${PWD} -I${PWD}/Makefiles
	rm ${BUILDDIR}/Makefile

ifeq (${HAVE_GP},1)
gp: libAtoms
QUIP_Core: libAtoms gp ${FOX}
GAProgs: libAtoms gp ${FOX} QUIP_Core
else
QUIP_Core: libAtoms ${FOX}
endif
QUIP_Util: libAtoms ${FOX} QUIP_Core
QUIP_Programs: libAtoms ${FOX} QUIP_Core QUIP_Utils 
Tests: libAtoms ${FOX} QUIP_Core QUIP_Utils

QUIP_Programs/Examples/%: libAtoms ${FOX} QUIP_Core QUIP_Utils
	ln -sf ${PWD}/QUIP_Programs/Makefile ${BUILDDIR}/Makefile
	targ=$@ ; ${MAKE} -C ${BUILDDIR} VPATH=${PWD}/QUIP_Programs/Examples -I${PWD} -I${PWD}/Makefiles $${targ#QUIP_Programs/Examples/}
	rm ${BUILDDIR}/Makefile

QUIP_Programs/%: libAtoms ${FOX} QUIP_Core QUIP_Utils
	ln -sf ${PWD}/QUIP_Programs/Makefile ${BUILDDIR}/Makefile
	targ=$@ ; ${MAKE} -C ${BUILDDIR} VPATH=${PWD}/QUIP_Programs -I${PWD} -I${PWD}/Makefiles $${targ#QUIP_Programs/}
	rm ${BUILDDIR}/Makefile

QUIP_Core/%: libAtoms ${FOX} QUIP_Core QUIP_Utils
	ln -sf ${PWD}/QUIP_Core/Makefile ${BUILDDIR}/Makefile
	targ=$@ ; ${MAKE} -C ${BUILDDIR} VPATH=${PWD}/QUIP_Core -I${PWD} -I${PWD}/Makefiles $${targ#QUIP_Core/}
	rm ${BUILDDIR}/Makefile

libAtoms/%: libAtoms 
	ln -sf ${PWD}/libAtoms/Makefile ${BUILDDIR}/Makefile
	targ=$@ ; ${MAKE} -C ${BUILDDIR} VPATH=${PWD}/libAtoms -I${PWD} -I${PWD}/Makefiles $${targ#libAtoms/}
	rm ${BUILDDIR}/Makefile

Tools/%: libAtoms ${FOX} QUIP_Core QUIP_Utils
	ln -sf ${PWD}/Tools/Makefile ${BUILDDIR}/Makefile
	targ=$@ ; ${MAKE} -C ${BUILDDIR} VPATH=${PWD}/Tools -I${PWD} -I${PWD}/Makefiles $${targ#Tools/}
	rm ${BUILDDIR}/Makefile


${BUILDDIR}: arch
	@if [ ! -d build.${QUIP_ARCH} ] ; then mkdir build.${QUIP_ARCH} ; fi


clean:
	for mods in  ${MODULES} ; do \
	  ln -sf ${PWD}/$$mods/Makefile ${BUILDDIR}/Makefile ; \
	  ${MAKE} -C ${BUILDDIR} -I${PWD} -I${PWD}/Makefiles clean ; \
	done ; \
	for dir in ${EXTRA_CLEAN_DIRS}; do \
	  cd $$dir; make clean; \
	done


doc: quip-reference-manual.pdf

quip-reference-manual.pdf:
	./Tools/mkdoc

atomeye:
	if [[ ! -d Tools/AtomEye ]]; then svn co svn+ssh://cvs.tcm.phy.cam.ac.uk/home/jrk33/repo/trunk/AtomEye Tools/AtomEye; fi
	make -C Tools/AtomEye QUIP_ROOT=${PWD}

quippy:
	make -C Tools/quippy install QUIP_ROOT=${PWD}

test:
	${MAKE} -C Tests -I${PWD} -I${PWD}/Makefiles -I${PWD}/${BUILDDIR}

! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
! H0 X
! H0 X   libAtoms+QUIP: atomistic simulation library
! H0 X
! H0 X   Portions of this code were written by
! H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
! H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
! H0 X
! H0 X   Copyright 2006-2010.
! H0 X
! H0 X   These portions of the source code are released under the GNU General
! H0 X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
! H0 X
! H0 X   If you would like to license the source code under different terms,
! H0 X   please contact Gabor Csanyi, gabor@csanyi.net
! H0 X
! H0 X   Portions of this code were written by Noam Bernstein as part of
! H0 X   his employment for the U.S. Government, and are not subject
! H0 X   to copyright in the USA.
! H0 X
! H0 X
! H0 X   When using this software, please cite the following reference:
! H0 X
! H0 X   http://www.libatoms.org
! H0 X
! H0 X  Additional contributions by
! H0 X    Alessio Comisso, Chiara Gattinoni, and Gianpietro Moras
! H0 X
! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

! print 1 out of every n frames
#include "error.inc"
program decimate
use libatoms_module
implicit none
  type(Atoms) :: at
  integer :: i, n, error
  type(dictionary) :: cli_params
  character(len=STRING_LENGTH) :: infilename, outfilename
  type(cinoutput) :: infile_io, outfile_io

  call system_initialise(verbosity=PRINT_SILENT)
  call verbosity_push(PRINT_NORMAL)

  call initialise(cli_params)
  call param_register(cli_params,"n",PARAM_MANDATORY, n, help_string="Number of frames to skip between printing")
  call param_register(cli_params,"infile","stdin", infilename, help_string="input filename")
  call param_register(cli_params,"outfile","stdout", outfilename, help_string="output filename")
  if (.not. param_read_args(cli_params)) then
    call system_abort("Usage: decimate n=(1) [infile=(stdin)] [outfile=(stdout)]")
  endif
  call finalise(cli_params)

  call initialise(infile_io, infilename, INPUT)
  call initialise(outfile_io, outfilename, OUTPUT)

  call read(at, infile_io, error=error)
  HANDLE_ERROR(error)
  call write(at, outfile_io)
  i = 0
  do while (error == 0)
    i = i + n
    call read(at, infile_io, frame=i, error=error)
    if (error /= 0) then
       if (error == ERROR_IO_EOF) exit
       HANDLE_ERROR(error)
    endif
    call write(at, outfile_io)
  end do

  call finalise(outfile_io)
  call finalise(infile_io)

  call verbosity_pop()
  call system_finalise()
end program decimate

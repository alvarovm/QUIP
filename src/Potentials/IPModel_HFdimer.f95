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

!X
!X IPModel_HFdimer
!X
!% Simple interatomic potential for an HF dimer: 
!%
!% Includes a linear spring between bonded H and F atoms, Coulomb interaction and short-range repulsion
!% between nonbonded atoms. The parametrisation was done from MP2 calculations. 
!% 
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
#include "error.inc"

module IPModel_HFdimer_module

use error_module
use system_module, only : dp, inoutput, print, operator(//)
use units_module
use dictionary_module
use paramreader_module
use linearalgebra_module
use atoms_types_module
use atoms_module

use mpi_context_module
use QUIP_Common_module

implicit none
private

include 'IPModel_interface.h'

public :: IPModel_HFdimer
type IPModel_HFdimer
  real(dp) :: cutoff = 10.0_dp
end type IPModel_HFdimer

logical, private :: parse_in_ip, parse_matched_label
type(IPModel_HFdimer), private, pointer :: parse_ip

interface Initialise
  module procedure IPModel_HFdimer_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_HFdimer_Finalise
end interface Finalise

interface Print
  module procedure IPModel_HFdimer_Print
end interface Print

interface Calc
  module procedure IPModel_HFdimer_Calc
end interface Calc

contains

subroutine IPModel_HFdimer_Initialise_str(this, args_str, param_str)
  type(IPModel_HFdimer), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str

  !  Add initialisation code here

end subroutine IPModel_HFdimer_Initialise_str

subroutine IPModel_HFdimer_Finalise(this)
  type(IPModel_HFdimer), intent(inout) :: this

  ! Add finalisation code here

end subroutine IPModel_HFdimer_Finalise


subroutine IPModel_HFdimer_Calc(this, at, e, local_e, f, virial, local_virial, args_str, mpi, error)
   type(IPModel_HFdimer), intent(inout):: this
   type(Atoms), intent(inout)      :: at
   real(dp), intent(out), optional :: e, local_e(:)
   real(dp), intent(out), optional :: f(:,:), local_virial(:,:)   !% Forces, dimensioned as \texttt{f(3,at%N)}, local virials, dimensioned as \texttt{local_virial(9,at%N)} 
   real(dp), intent(out), optional :: virial(3,3)
   character(len=*), optional      :: args_str
   type(MPI_Context), intent(in), optional :: mpi
   integer, intent(out), optional :: error

   ! Add calc() code here


   real(dp) :: energy, force(3,4)
   real(dp) :: rHF1, rHF2, rFF, rF1, rF2, dr1(3), dr2(3), drFF(3), drF1(3), drF2(3), rHH, rH1F2, rH2F1, drHH(3), drH1F2(3), drH2F1(3), q2
   real(dp), parameter :: kHF = 0.0_dp ! 37.84_dp   ! H-F spring constant
   real(dp), parameter :: kConf = 0.0_dp ! 0.15_dp  ! confinement 
   real(dp), parameter :: d0HF = 0.9_dp, BFF = 0.269268123658040_dp, r0FF = 2.0312819622_dp, r0HF = 1.1564_dp, BHF = 0.141733063687659_dp, q=0.43_dp

   INIT_ERROR(error)



   ! Hydrogen Fluoride dimer potential
   ! spring constant between H-F and repulsive interaction between Fs, repulsive interaction between nonbonded HFs, Coulomb interaction between nonbonded things
   ! The order in the Atoms object must be H-F H-F
   ! 
   ! Harmonic confining potential on Fs

   rHF1 = distance_min_image(at, 1, 2)
   rHF2 = distance_min_image(at, 3, 4)
   rFF = distance_min_image(at, 2, 4)
   rHH = distance_min_image(at,1,3)
   rH1F2 = distance_min_image(at,1,4)
   rH2F1 = distance_min_image(at,2,3)

   rF1 = distance_min_image(at, 2, (/0.0_dp, 0.0_dp, 0.0_dp/))
   rF2 = distance_min_image(at, 4, (/0.0_dp, 0.0_dp, 0.0_dp/))

   ! Bonded energy terms
   energy = kHF*(rHF1-d0HF)**2 + kHF*(rHF2-d0HF)**2

   ! repulsive terms
   energy = energy + exp(-(rFF-r0FF)/BFF) + exp(-(rH1F2-r0HF)/BHF) + exp(-(rH2F1-r0HF)/BHF)

   ! confinement 
   energy = energy + kConf*rF1**2 + kConf*rF2**2 

   ! Coulomb Energy
   q2 = HARTREE*BOHR*q*q
   energy = energy + q2*(&
        (+1.0_dp)/rHH +   & ! H1-H2
        (-1.0_dp)/rH1F2 + & ! H1-F2
        (+1.0_dp)/rFF +   & ! F1-F2
        (-1.0_dp)/rH2F1)    ! F1-H2

   !Forces

   dr1 = diff_min_image(at, 1, 2)/rHF1
   dr2 = diff_min_image(at, 3, 4)/rHF2
   drFF = diff_min_image(at, 2, 4)/rFF
   drF1 = diff_min_image(at, 2, (/0.0_dp, 0.0_dp, 0.0_dp/))/rF1
   drF2 = diff_min_image(at, 4, (/0.0_dp, 0.0_dp, 0.0_dp/))/rF2

   drHH = diff_min_image(at,1,3)/rHH
   drH1F2 = diff_min_image(at,1,4)/rH1F2
   drH2F1 = diff_min_image(at,2,3)/rH2F1

   force(:,1) = 2.0_dp*kHF*(rHF1-d0HF)*dr1 -q2/rHH**2*drHH + q2/rH1F2**2*drH1F2 - 1.0_dp/BHF*exp(-(rH1F2-r0HF)/BHF)*drH1F2 
   force(:,2) = -2.0_dp*kHF*(rHF1-d0HF)*dr1 - 1.0_dp/BFF*exp(-(rFF-r0FF)/BFF) * drFF + 2.0_dp*kConf*rF1*drF1 +q2/rH2F1**2*drH2F1 -q2/rFF**2*drFF - 1.0_dp/BHF*exp(-(rH2F1-r0HF)/BHF)*drH2F1
   force(:,3) = 2.0_dp*kHF*(rHF2-d0HF)*dr2 +q2/rHH**2*drHH - q2/rH2F1**2*drH2F1 + 1.0_dp/BHF*exp(-(rH2F1-r0HF)/BHF)*drH2F1
   force(:,4) = -2.0_dp*kHF*(rHF2-d0HF)*dr2 + 1.0_dp/BFF*exp(-(rFF-r0FF)/BFF) * drFF + 2.0_dp*kConf*rF2*drF2 -q2/rH1F2**2*drH1F2 +q2/rFF**2*drFF + 1.0_dp/BHF*exp(-(rH1F2-r0HF)/BHF)*drH1F2


   if (present(e)) e = energy
   if (present(local_e)) then
      call check_size('Local_E',local_e,(/at%N/),'IPModel_HFdimer_Calc', error)
      local_e = 0.0_dp
   endif
   if (present(f)) then
      call check_size('Force',f,(/3,at%Nbuffer/),'IPModel_HFdimer_Calc', error)
      f = force
   end if
   if (present(virial)) virial = 0.0_dp
   if (present(local_virial)) then
      call check_size('Local_virial',local_virial,(/9,at%Nbuffer/),'IPModel_HFdimer_Calc', error)
      local_virial = 0.0_dp
   endif


end subroutine IPModel_HFdimer_Calc


subroutine IPModel_HFdimer_Print(this, file)
  type(IPModel_HFdimer), intent(in) :: this
  type(Inoutput), intent(inout),optional :: file

  call Print("IPModel_HFdimer : HFdimer Potential", file=file)
  call Print("IPModel_HFdimer : cutoff = " // this%cutoff, file=file)

end subroutine IPModel_HFdimer_Print


end module IPModel_HFdimer_module

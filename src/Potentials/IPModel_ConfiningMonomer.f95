! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
! H0 X
! H0 X   libAtoms+QUIP: atomistic simulation library
! H0 X
! H0 X   Portions of this code were written by
! H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
! H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
! H0 X
! H0 X   Copyright 2006-2017.
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
!X IPModel_ConfiningMonomer
!X
!% Potential to keep monomers together, currently hardcoded for methane
!% (but should be easy to modify for any single-centre molecule)
!%
!% Simple harmonic on C-H bonds and H-C-H angle cosines 
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
#include "error.inc"

module IPModel_ConfiningMonomer_module

use error_module
use system_module, only : dp, inoutput, print, PRINT_VERBOSE, PRINT_NERD, operator(//)
use dictionary_module
use paramreader_module
use linearalgebra_module
use atoms_types_module
use atoms_module
use topology_module

use mpi_context_module
use QUIP_Common_module

implicit none
private

include 'IPModel_interface.h'

public :: IPModel_ConfiningMonomer
type IPModel_ConfiningMonomer
  real(dp) :: cutoff = 0.0_dp
  real(dp) :: kbond = 0.0_dp
  real(dp) :: kangle = 0.0_dp
  real(dp) :: bond_r0 = 0.0_dp
  real(dp) :: angle_cos0 = 0.0_dp
end type IPModel_ConfiningMonomer

logical, private :: parse_in_ip, parse_matched_label
type(IPModel_ConfiningMonomer), private, pointer :: parse_ip

interface Initialise
  module procedure IPModel_ConfiningMonomer_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_ConfiningMonomer_Finalise
end interface Finalise

interface Print
  module procedure IPModel_ConfiningMonomer_Print
end interface Print

interface Calc
  module procedure IPModel_ConfiningMonomer_Calc
end interface Calc

contains

subroutine IPModel_ConfiningMonomer_Initialise_str(this, args_str, param_str, error)
  type(IPModel_ConfiningMonomer), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str
  type(Dictionary) :: params
  integer, optional, intent(out):: error


  INIT_ERROR(error)
  call Finalise(this)

  call initialise(params)
  call param_register(params, 'kbond', '0.0', this%kbond, help_string='Strength of quadratic restraint on C-H bonds.  Potential is kconf*(r-r0)^2')
  call param_register(params, 'kangle', '0.0', this%kangle, help_string='Strength of quadratic restraint on H-C-H cosines.  Potential is kconf*(cos(theta)-cos(theta0))^2')
  call param_register(params, 'bond_r0', '0.0', this%bond_r0, help_string='Equilibrium bond length for C-H bonds.')
  call param_register(params, 'angle_cos0', '0.0', this%angle_cos0, help_string='Cosine of equilibrium bond angle for H-C-H triplets.')
  call param_register(params, 'cutoff', '0.0', this%cutoff, help_string='Cutoff for finding methane monomers')
  if(.not. param_read_line(params, args_str, ignore_unknown=.true., task='IPModel_ConfiningMonomer_Initialise args_str')) then
     RAISE_ERROR("IPModel_ConfiningMonomer_Init failed to parse args_str='"//trim(args_str)//"'", error)
  end if
  call finalise(params)

end subroutine IPModel_ConfiningMonomer_Initialise_str

subroutine IPModel_ConfiningMonomer_Finalise(this)
  type(IPModel_ConfiningMonomer), intent(inout) :: this

  ! Add finalisation code here

end subroutine IPModel_ConfiningMonomer_Finalise


subroutine IPModel_ConfiningMonomer_Calc(this, at, e, local_e, f, virial, local_virial, args_str, mpi, error)
   type(IPModel_ConfiningMonomer), intent(inout):: this
   type(Atoms), intent(inout)      :: at
   real(dp), intent(out), optional :: e, local_e(:)
   real(dp), intent(out), optional :: f(:,:), local_virial(:,:)   !% Forces, dimensioned as \texttt{f(3,at%N)}, local virials, dimensioned as \texttt{local_virial(9,at%N)} 
   real(dp), intent(out), optional :: virial(3,3)
   character(len=*), optional      :: args_str
   type(MPI_Context), intent(in), optional :: mpi
   integer, intent(out), optional :: error

   ! Add calc() code here

   ! Confining potential for methanes - first find general monomers, then place
   ! harmonic restraints on bonds and angles.

   integer, dimension(:,:), allocatable :: monomer_index
   logical, dimension(:), allocatable :: is_associated
   real(dp) :: energy, force(3,at%N)

   type(Dictionary) :: params
   character(STRING_LENGTH) :: atom_mask_name, pers_idces_name
   logical :: has_atom_mask_name, has_pers_idces_name
   logical, dimension(:), pointer :: atom_mask_pointer
   integer, dimension(:), pointer :: pers_idces_pointer
   logical :: called_from_lammps

   integer :: mon_i, i_atomic, atom_i, rank_j, atom_j, rank_k, atom_k
   real(dp) :: e_pair, d_epair_dr, rij(3), rik(3), rij_mag, rik_mag, rij_norm(3), rik_norm(3)
   real(dp) :: e_trip, d_etrip_dcos, cos_ijk, fij(3), fik(3)
   real(dp) :: virial_i(3,3), virial_j(3,3), virial_k(3,3)


   INIT_ERROR(error)

   if(present(args_str)) then
      call initialise(params)

      call param_register(params, 'atom_mask_name', 'NONE', atom_mask_name, has_value_target=has_atom_mask_name, &
      help_string="Name of a logical property in the atoms object. For monomers where this property is true the Potential is " // &
      "calculated.")

      call param_register(params, 'lammps', 'F', called_from_lammps, help_string="Should be true if this potential is called from LAMMPS")

      call param_register(params, 'pers_idces_name', 'NONE', pers_idces_name, has_value_target=has_pers_idces_name, &
                          help_string="Name of an integer property in the atoms object containing the original LAMMPS atom ids (only needed if &
                                       called from lammps)")

      if (.not. param_read_line(params,args_str,ignore_unknown=.true.,task='general_dimer_calc args_str')) then
         RAISE_ERROR("IPModel_ConfiningMonomer_Calc failed to parse args_str='"//trim(args_str)//"'", error)
      endif

      call finalise(params)

      if( has_atom_mask_name ) then
         if (.not. assign_pointer(at, trim(atom_mask_name), atom_mask_pointer)) then
            RAISE_ERROR("IPModel_ConfiningMonomer_Calc did not find "//trim(atom_mask_name)//" property in the atoms object.", error)
         endif
      else
         atom_mask_pointer => null()
      endif

      if( called_from_lammps ) then
         if (.not. has_pers_idces_name) then
            RAISE_ERROR("IPModel_ConfiningMonomer_Calc needs persistent indices if working with lammps.", error)
         endif
         if (.not. assign_pointer(at, trim(pers_idces_name), pers_idces_pointer)) then
            RAISE_ERROR("IPModel_ConfiningMonomer_Calc did not find "//trim(pers_idces_name)//" property in the atoms object.", error)
         endif
      endif
   else
       called_from_lammps = .false.
       atom_mask_pointer => null()
   endif

   if (present(e)) e = 0.0_dp
   if (present(local_e)) then
      call check_size('Local_E',local_e,(/at%N/),'IPModel_ConfiningMonomer_Calc', error)
      local_e = 0.0_dp
   endif
   if (present(f)) then
      call check_size('Force',f,(/3,at%Nbuffer/),'IPModel_ConfiningMonomer_Calc', error)
      f = 0.0_dp
   end if
   if (present(virial)) virial = 0.0_dp
   if (present(local_virial)) then
      call check_size('Local_virial',local_virial,(/9,at%Nbuffer/),'IPModel_ConfiningMonomer_Calc', error)
      local_virial = 0.0_dp
   endif

   allocate(is_associated(at%N))
   is_associated = .false.
   if (called_from_lammps) then
      call shuffle(at, pers_idces_pointer, error)
   endif
   call find_general_monomer(at, monomer_index, (/6, 1, 1, 1, 1/), is_associated, this%cutoff, general_ordercheck=.false., error=error)

   call print("Found " // size(monomer_index,  2) // " monomers", PRINT_VERBOSE)
   if(.not. all(is_associated)) then
      call print("WARNING: IP ConfiningMonomer: not all atoms assigned to a methane monomer. If you have partial monomers this is OK.", PRINT_VERBOSE)
   end if

   ! First, loop over monomers.  These are also the centres of angle triplets.
   do mon_i = 1, size(monomer_index, 2)
      ! Copied from IPModel_SW.f95 -- let's hope this works.
      if (present(mpi)) then
         if (mpi%active) then
            if (mod(mon_i-1, mpi%n_procs) /= mpi%my_proc) cycle
         endif
      endif
      atom_i = monomer_index(1, mon_i)
      ! Only evaluate the monomer if the central C atom is local - should check
      ! how lammps accounts for forces on non-local atoms
      if (associated(atom_mask_pointer)) then
         if (.not. atom_mask_pointer(atom_i)) cycle
      end if

      call print("Atom " // atom_i // " has " // n_neighbours(at, atom_i, max_dist=this%cutoff) // " neighbours", PRINT_VERBOSE)
      do rank_j = 1, n_neighbours(at, atom_i)
         atom_j = neighbour(at, atom_i, rank_j, distance=rij_mag, diff=rij, cosines=rij_norm, max_dist=this%cutoff)
         if (atom_j .eq. 0) cycle  ! Neighbour outside of cutoff
         if (rij_mag .feq. 0.0_dp) cycle  ! Somehow got self
         ! This really shouldn't happen in any normal cases, but account for it anyways
         if (.not. (any(monomer_index(2:5, mon_i) .eq. atom_j))) then
            call print("WARNING: Stray neighbour " // atom_j // ", rank " // rank_j // ", of atom " // atom_i // " detected!", PRINT_VERBOSE)
            cycle
         end if

         ! Pairwise forces and energies
         e_pair = this%kbond * (rij_mag - this%bond_r0)**2
         d_epair_dr = 2.0_dp * this%kbond * (rij_mag - this%bond_r0)

         if (present(e)) e = e + e_pair
         if (present(local_e)) then
            ! Eh, let's just concentrate all the 'local' quantities on the monomer centres.
            local_e(atom_i) = local_e(atom_i) + e_pair
         end if
         if (present(f)) then
            f(:, atom_j) = f(:, atom_j) - 1.0_dp * d_epair_dr * rij_norm
            f(:, atom_i) = f(:, atom_i) + 1.0_dp * d_epair_dr * rij_norm
         end if
         if (present(virial) .or. present(local_virial)) then
            virial_i = -1.0 * d_epair_dr * rij_mag * (rij_norm .outer. rij_norm)
         end if
         if (present(virial)) virial = virial + virial_i
         if (present(local_virial)) then
            local_virial(:, atom_i) = local_virial(:, atom_i) + reshape(virial_i, (/9/))
         end if

         do rank_k = 1, n_neighbours(at, atom_i)
            atom_k = neighbour(at, atom_i, rank_k, distance=rik_mag, diff=rik, cosines=rik_norm, max_dist=this%cutoff)
            if (atom_k .eq. 0) cycle
            ! Again, shouldn't happen, but better to be safe
            if (.not. (any(monomer_index(2:5, mon_i) .eq. atom_k))) cycle
            if (atom_k <= atom_j) cycle

            cos_ijk = sum(rij_norm*rik_norm)
            e_trip = this%kangle * (cos_ijk - this%angle_cos0)**2
            d_etrip_dcos = 2.0_dp * this%kangle * (cos_ijk - this%angle_cos0)
            if (present(e)) e = e + e_trip
            if (present(local_e)) then
               ! Hm, the triplet local quantities can be assigned to the outer atoms
               local_e(atom_j) = local_e(atom_j) + 0.5_dp * e_trip
               local_e(atom_k) = local_e(atom_k) + 0.5_dp * e_trip
            end if
            if (present(f) .or. present(virial) .or. present(local_virial)) then
               ! Apparently these need to have the opposite sign from what I
               ! originally thought - isn't it f_i = -grad_i(e) though?
               fij = 1.0_dp * d_etrip_dcos * (rik_norm - rij_norm*cos_ijk) / rij_mag
               fik = 1.0_dp * d_etrip_dcos * (rij_norm - rik_norm*cos_ijk) / rik_mag
            end if
            if (present(f)) then
               f(:, atom_i) = f(:, atom_i) + fij + fik
               f(:, atom_j) = f(:, atom_j) - fij
               f(:, atom_k) = f(:, atom_k) - fik
            end if
            if (present(virial) .or. present(local_virial)) then
               ! TODO check these signs
               virial_j = -1.0_dp * d_etrip_dcos * ((rik_norm .outer. rij_norm) - (rij_norm .outer. rij_norm)*cos_ijk)
               virial_k = -1.0_dp * d_etrip_dcos * ((rij_norm .outer. rik_norm) - (rik_norm .outer. rik_norm)*cos_ijk)
            end if
            if (present(virial)) virial = virial + virial_j + virial_k
            if (present(local_virial)) then
               local_virial(:, atom_i) = local_virial(:, atom_i) + reshape(virial_j, (/9/)) + reshape(virial_k, (/9/))
            end if
         end do
      end do
   end do

   ! Copied from IPModel_SW.xml
   if (present(mpi)) then
      if (present(e)) e = sum(mpi, e)
      if (present(local_e)) call sum_in_place(mpi, local_e)
      if (present(f)) call sum_in_place(mpi, f)
      if (present(virial)) call sum_in_place(mpi, virial)
      if (present(local_virial)) call sum_in_place(mpi, local_virial)
   endif

   deallocate(monomer_index)
   deallocate(is_associated)

end subroutine IPModel_ConfiningMonomer_Calc


subroutine IPModel_ConfiningMonomer_Print(this, file)
  type(IPModel_ConfiningMonomer), intent(in) :: this
  type(Inoutput), intent(inout),optional :: file

  call Print("IPModel_ConfiningMonomer : ConfiningMonomer Potential", file=file)
  call Print("IPModel_ConfiningMonomer : cutoff = " // this%cutoff, file=file)
  call Print("IPModel_ConfiningMonomer : kbond = " // this%kbond, file=file)
  call Print("IPModel_ConfiningMonomer : kangle = " // this%kangle, file=file)
  call Print("IPModel_ConfiningMonomer : bond_r0 = " // this%bond_r0, file=file)
  call Print("IPModel_ConfiningMonomer : angle_cos0 = " // this%angle_cos0, file=file)

end subroutine IPModel_ConfiningMonomer_Print


end module IPModel_ConfiningMonomer_module

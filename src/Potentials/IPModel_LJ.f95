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
!X IPModel_LJ module  
!X
!% Module for Lennard-Jones pair potential.
!% \begin{equation} 
!%   \nonumber
!%     V(r) = 4 \epsilon \left[  \left( \frac{\sigma}{r} \right)^{12} - \left( \frac{\sigma}{r} \right)^6 \right] 
!% \end{equation} 
!% For parameters see Ashcroft and Mermin, {\it Solid State Physics}. 
!%
!% NB: The energy calculation in the code is
!% \begin{equation*}
!%   V(r) = \epsilon_{12} (\sigma/r)^{12} - \epsilon_6 (\sigma/r)^6
!% \end{equation*}
!% (plus energy and linear force shift, if applicable)
!% hence the factor 4 has to be included in the potential XML file.
!%
!% If requested, tail corrections are added for all pairs with a
!% nonzero $\epsilon_6$ (i.e. a nonzero sixth-power tail).  This
!% requires all such pairs to have equal cutoffs and smooth cutoff
!% widths.  See the documentation for the 'DispTS' potential for
!% more information on how these corrections are computed in QUIP.
!%
!% The IPModel_LJ object contains all the parameters read from a
!% 'LJ_params' XML stanza.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
#include "error.inc"

module IPModel_LJ_module

use error_module
use system_module, only : dp, inoutput, print, verbosity_push_decrement, verbosity_pop, split_string_simple, operator(//)
use dictionary_module
use paramreader_module
use linearalgebra_module
use units_module, only : PI
use atoms_types_module
use atoms_module

use mpi_context_module
use QUIP_Common_module

implicit none

private 

include 'IPModel_interface.h'

public :: IPModel_LJ
type IPModel_LJ
  integer :: n_types = 0         !% Number of atomic types. 
  integer, allocatable :: atomic_num(:), type_of_atomic_num(:)  !% Atomic number dimensioned as \texttt{n_types}. 

  real(dp) :: cutoff = 0.0_dp    !% Cutoff for computing connection.

  real(dp), allocatable :: sigma(:,:), eps6(:,:), eps12(:,:), cutoff_a(:,:), energy_shift(:,:), linear_force_shift(:,:), smooth_cutoff_width(:,:) !% IP parameters.
  real(dp) :: tail_corr_smooth_factor
  real(dp) :: tail_corr_const
  real(dp), allocatable :: tail_c6_coeffs(:,:)
  logical :: only_inter_resid = .false.
  logical :: do_tail_corrections = .false.
  logical :: tail_smooth_cutoff = .false.

  character(len=STRING_LENGTH) label

end type IPModel_LJ

logical, private :: parse_in_ip, parse_matched_label
type(IPModel_LJ), private, pointer :: parse_ip

interface Initialise
  module procedure IPModel_LJ_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_LJ_Finalise
end interface Finalise

interface Print
  module procedure IPModel_LJ_Print
end interface Print

interface Calc
  module procedure IPModel_LJ_Calc
end interface Calc

contains

subroutine IPModel_LJ_Initialise_str(this, args_str, param_str)
  type(IPModel_LJ), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str

  real(dp) :: tc_cutoff = -1.0_dp
  real(dp) :: tc_ctw = -1.0_dp
  integer :: ti,tj

  type(Dictionary) :: params

  call Finalise(this)

  call initialise(params)
  this%label = ''
  call param_register(params, 'label', '', this%label, help_string="No help yet.  This source file was $LastChangedBy$")
  if (.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_LJ_Initialise_str args_str')) then
    call system_abort("IPModel_LJ_Initialise_str failed to parse label from args_str="//trim(args_str))
  endif
  call finalise(params)

  call IPModel_LJ_read_params_xml(this, param_str)

  this%cutoff = maxval(this%cutoff_a)

  ! Check whether we can even do tail corrections, then set up the constants
  if (this%do_tail_corrections) then
    tc_cutoff = -1.0_dp
    allocate(this%tail_c6_coeffs(this%n_types, this%n_types))
    do ti = 1,this%n_types
      do tj = ti,this%n_types
        if (this%eps6(ti,tj) .fne. 0.0_dp) then

          if ((this%energy_shift(ti,tj) .fne. 0.0_dp) .or. &
              (this%linear_force_shift(ti,tj) .fne. 0.0_dp)) then
            call system_abort("IPModel_LJ_Initialise_str: Tail corrections not implemented with &
                               energy or force shifts")
          endif

          if (tc_cutoff .feq. -1.0_dp) then
            tc_cutoff = this%cutoff_a(ti,tj)
            tc_ctw = this%smooth_cutoff_width(ti,tj)
          else if (this%cutoff_a(ti,tj) .fne. tc_cutoff) then
            call system_abort("IPModel_LJ_Initialise_str: Tail corrections require all &
                               cutoffs to be equal; " // this%cutoff_a(ti,tj) //" =/= "// tc_cutoff)
          else if (this%smooth_cutoff_width(ti,tj) .fne. tc_ctw) then
            call system_abort("IPModel_LJ_Initialise_str: Tail corrections require all &
                               cutoff transition widths to be equal; " // this%smooth_cutoff_width(ti,tj) //" =/= "// tc_ctw)
          endif
          this%tail_c6_coeffs(ti,tj) = this%eps6(ti,tj) * this%sigma(ti,tj)**6
        else
          this%tail_c6_coeffs(ti,tj) = 0.0_dp
        endif
        this%tail_c6_coeffs(tj,ti) = this%tail_c6_coeffs(ti,tj)
      enddo
    enddo
    if (tc_cutoff .fgt. 0.0_dp) then
      if (tc_ctw .fgt. 0.0_dp) then
        this%tail_smooth_cutoff = .true.
        this%tail_corr_const = -2.0_dp * PI / 3.0_dp * &
            ((1.0_dp - this%tail_corr_smooth_factor) / (tc_cutoff - tc_ctw)**3 &
             + this%tail_corr_smooth_factor / tc_cutoff**3)
      else
        this%tail_smooth_cutoff = .false.
        this%tail_corr_const = -2.0_dp * PI / 3.0_dp / tc_cutoff**3
      endif
    else
      this%tail_corr_const = 0.0_dp
      this%do_tail_corrections = .false.
    endif
  endif

end subroutine IPModel_LJ_Initialise_str

subroutine IPModel_LJ_Finalise(this)
  type(IPModel_LJ), intent(inout) :: this

  if (allocated(this%atomic_num)) deallocate(this%atomic_num)
  if (allocated(this%type_of_atomic_num)) deallocate(this%type_of_atomic_num)

  if (allocated(this%sigma)) deallocate(this%sigma)
  if (allocated(this%eps6)) deallocate(this%eps6)
  if (allocated(this%eps12)) deallocate(this%eps12)
  if (allocated(this%cutoff_a)) deallocate(this%cutoff_a)
  if (allocated(this%energy_shift)) deallocate(this%energy_shift)
  if (allocated(this%linear_force_shift)) deallocate(this%linear_force_shift)
  if (allocated(this%smooth_cutoff_width)) deallocate(this%smooth_cutoff_width)
  if (allocated(this%tail_c6_coeffs)) deallocate(this%tail_c6_coeffs)

  this%n_types = 0
  this%label = ''
end subroutine IPModel_LJ_Finalise

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% The potential calculator: this routine computes energy, forces and the virial.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_LJ_Calc(this, at, e, local_e, f, virial, local_virial, args_str, mpi, error)
  type(IPModel_LJ), intent(inout) :: this
  type(Atoms), intent(inout) :: at
  real(dp), intent(out), optional :: e, local_e(:) !% \texttt{e} = System total energy, \texttt{local_e} = energy of each atom, vector dimensioned as \texttt{at%N}.  
  real(dp), intent(out), optional :: f(:,:), local_virial(:,:)   !% Forces, dimensioned as \texttt{f(3,at%N)}, local virials, dimensioned as \texttt{local_virial(9,at%N)} 
  real(dp), intent(out), optional :: virial(3,3)   !% Virial
  character(len=*), intent(in), optional      :: args_str
  type(MPI_Context), intent(in), optional :: mpi
  integer, intent(out), optional :: error

  real(dp), pointer :: w_e(:)
  integer i, ji, j, ti, tj, d
  real(dp) :: dr(3), dr_mag
  real(dp) :: de, de_dr
  logical :: i_is_min_image

  integer :: i_calc, n_extra_calcs
  character(len=20) :: extra_calcs_list(10)

  logical :: do_flux = .false.
  real(dp), pointer :: velo(:,:)
  real(dp) :: flux(3)

  integer, pointer :: resid(:)
  real(dp) :: c6_sum, tail_correction

  type(Dictionary)                :: params
  logical :: has_atom_mask_name
  character(STRING_LENGTH) :: atom_mask_name
  real(dp) :: r_scale, E_scale
  logical :: do_rescale_r, do_rescale_E

  INIT_ERROR(error)

  if (present(e)) e = 0.0_dp
  if (present(local_e)) then
     call check_size('Local_E',local_e,(/at%N/),'IPModel_LJ_Calc', error)
     local_e = 0.0_dp
  endif
  if (present(f)) then 
     call check_size('Force',f,(/3,at%Nbuffer/),'IPModel_LJ_Calc', error)
     f = 0.0_dp
  end if
  if (present(virial)) virial = 0.0_dp
  if (present(local_virial)) then
     call check_size('Local_virial',local_virial,(/9,at%Nbuffer/),'IPModel_LJ_Calc', error)
     local_virial = 0.0_dp
     RAISE_ERROR("IPModel_LJ_Calc: local_virial calculation requested but not supported yet.", error)
  endif

  if (this%only_inter_resid) then
     if (.not. assign_pointer(at, "resid", resid)) then
       RAISE_ERROR("IPModel_LJ_Calc calculation with only_inter_resid=T requires resid field", error)
     endif
  end if

  if (present(args_str)) then
    if (len_trim(args_str) > 0) then
      n_extra_calcs = parse_extra_calcs(args_str, extra_calcs_list)
      if (n_extra_calcs > 0) then
	do i_calc=1, n_extra_calcs
	  select case(trim(extra_calcs_list(i_calc)))
	    case("flux")
	      if (.not. assign_pointer(at, "velo", velo)) then
		RAISE_ERROR("IPModel_LJ_Calc Flux calculation requires velo field", error)
              endif
	      do_flux = .true.
	      flux = 0.0_dp
	    case default
	      RAISE_ERROR("Unsupported extra_calc '"//trim(extra_calcs_list(i_calc))//"'", error)
	  end select
	end do
      endif ! n_extra_calcs
    endif ! len_trim(args_str)
    call initialise(params)
    call param_register(params, 'atom_mask_name', 'NONE', atom_mask_name, has_value_target=has_atom_mask_name, help_string="No help yet.  This source file was $LastChangedBy$")
    call param_register(params, 'r_scale', '1.0',r_scale, has_value_target=do_rescale_r, help_string="Recaling factor for distances. Default 1.0.")
    call param_register(params, 'E_scale', '1.0',E_scale, has_value_target=do_rescale_E, help_string="Recaling factor for energy. Default 1.0.")

    if(.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_LJ_Calc args_str')) then
       RAISE_ERROR("IPModel_LJ_Calc failed to parse args_str='"//trim(args_str)//"'",error)
    endif
    call finalise(params)
    if(has_atom_mask_name) then
       RAISE_ERROR('IPModel_LJ_Calc: atom_mask_name found, but not supported', error)
    endif
    if (do_rescale_r .or. do_rescale_E) then
       RAISE_ERROR("IPModel_LJ_Calc: rescaling of potential with r_scale and E_scale not yet implemented!", error)
    end if

  endif ! present(args_str)

  if (.not. assign_pointer(at, "weight", w_e)) nullify(w_e)

  c6_sum = 0.0_dp
  do i = 1, at%N
    i_is_min_image = is_min_image(at,i)

    if (present(mpi)) then
       if (mpi%active) then
	 if (mod(i-1, mpi%n_procs) /= mpi%my_proc) cycle
       endif
    endif

    ti = get_type(this%type_of_atomic_num, at%Z(i))

    ! Might be optimized if we have only_inter_resid=F
    ! Can then just count number of pairs of each type
    if (this%do_tail_corrections) then
      do j = i+1, at%N
        if (this%only_inter_resid) then
          if (resid(i) == resid(j)) cycle
        endif
        tj = get_type(this%type_of_atomic_num, at%Z(j))
        if (this%tail_c6_coeffs(tj,ti) .fne. 0.0_dp) then
          c6_sum = c6_sum + 2*this%tail_c6_coeffs(tj,ti)
        endif
      enddo
    endif

    do ji = 1, n_neighbours(at, i)
      j = neighbour(at, i, ji, dr_mag, cosines = dr)

      if (dr_mag .feq. 0.0_dp) cycle
      !if ((i < j) .and. i_is_min_image) cycle
      if ((i < j)) cycle

      if (this%only_inter_resid) then
	 if (resid(i) == resid(j)) cycle
      end if

      tj = get_type(this%type_of_atomic_num, at%Z(j))

      if (present(e) .or. present(local_e)) then
	de = IPModel_LJ_pairenergy(this, ti, tj, dr_mag)

	if (present(local_e)) then
	  local_e(i) = local_e(i) + 0.5_dp*de
          !if(i_is_min_image) local_e(j) = local_e(j) + 0.5_dp*de
          if(i/=j) local_e(j) = local_e(j) + 0.5_dp*de
	endif
	if (present(e)) then
	  if (associated(w_e)) then
	    de = de*0.5_dp*(w_e(i)+w_e(j))
	  endif
          !if(i_is_min_image) then
          !   e = e + de
          !else
          if(i==j) then
             e = e + 0.5_dp*de
          else
             e = e + de
          endif
          !endif
	endif
      endif
      if (present(f) .or. present(virial) .or. do_flux) then
	de_dr = IPModel_LJ_pairenergy_deriv(this, ti, tj, dr_mag)
	if (associated(w_e)) then
	  de_dr = de_dr*0.5_dp*(w_e(i)+w_e(j))
	endif
	if (present(f)) then
	  f(:,i) = f(:,i) + de_dr*dr
	  !if(i_is_min_image) f(:,j) = f(:,j) - de_dr*dr
	  if(i/=j) f(:,j) = f(:,j) - de_dr*dr
	endif
	if (do_flux) then
	  ! -0.5 (v_i + v_j) . F_ij * dr_ij
	  flux = flux - 0.5_dp*sum((velo(:,i)+velo(:,j))*(de_dr*dr))*(dr*dr_mag)
	endif
	if (present(virial)) then
	  !if(i_is_min_image) then
          !   virial = virial - de_dr*(dr .outer. dr)*dr_mag
          !else
          if(i==j) then
             virial = virial - 0.5_dp*de_dr*(dr .outer. dr)*dr_mag
          else
             virial = virial - de_dr*(dr .outer. dr)*dr_mag
          endif
          !endif
	endif
      endif
    end do
  end do

  if (this%do_tail_corrections) then
     tail_correction = c6_sum * this%tail_corr_const / cell_volume(at)
     if (present(e)) e = e + tail_correction
     if (present(virial)) then
        do d = 1, 3
          if (this%tail_smooth_cutoff) then
            ! Seems counterintuitive, but the math works out (for r^-6 potentials)
            virial(d,d) = virial(d,d) + tail_correction
          else
            virial(d,d) = virial(d,d) + 2*tail_correction
          endif
        enddo
     endif
  endif

  if (present(mpi)) then
     if (present(e)) e = sum(mpi, e)
     if (present(local_e)) call sum_in_place(mpi, local_e)
     if (present(virial)) call sum_in_place(mpi, virial)
     if (present(f)) call sum_in_place(mpi, f)
  endif
  if (do_flux) then
    flux = flux / cell_volume(at)
    if (present(mpi)) call sum_in_place(mpi, flux)
    call set_value(at%params, "Flux", flux)
  endif

end subroutine IPModel_LJ_Calc

!% This routine computes the two-body term for a pair of atoms  separated by a distance r.
function IPModel_LJ_pairenergy(this, ti, tj, r)
  type(IPModel_LJ), intent(in) :: this
  integer, intent(in) :: ti, tj   !% Atomic types.
  real(dp), intent(in) :: r       !% Distance.
  real(dp) :: IPModel_LJ_pairenergy

  real(dp) :: tpow

  if ((r .feq. 0.0_dp) .or. (r > this%cutoff_a(ti,tj))) then
    IPModel_LJ_pairenergy = 0.0_dp
    return
  endif

  tpow = (this%sigma(ti,tj)/r)**6

  IPModel_LJ_pairenergy = (this%eps12(ti,tj)*tpow*tpow - this%eps6(ti,tj)*tpow) - this%energy_shift(ti,tj) - &
  & this%linear_force_shift(ti,tj)*(r-this%cutoff_a(ti,tj))

  if (.not. (this%smooth_cutoff_width(ti,tj) .feq. 0.0_dp)) then
    IPModel_LJ_pairenergy = IPModel_LJ_pairenergy*poly_switch(r,this%cutoff_a(ti,tj),this%smooth_cutoff_width(ti,tj))
  end if

end function IPModel_LJ_pairenergy

!% Derivative of the two-body term.
function IPModel_LJ_pairenergy_deriv(this, ti, tj, r)
  type(IPModel_LJ), intent(in) :: this
  integer, intent(in) :: ti, tj   !% Atomic types.
  real(dp), intent(in) :: r       !% Distance.
  real(dp) :: IPModel_LJ_pairenergy_deriv

  real(dp) :: tpow

  if ((r .feq. 0.0_dp) .or. (r > this%cutoff_a(ti,tj))) then
    IPModel_LJ_pairenergy_deriv = 0.0_dp
    return
  endif

  tpow = (this%sigma(ti,tj)/r)**6

  IPModel_LJ_pairenergy_deriv = (-12.0_dp*this%eps12(ti,tj)*tpow*tpow + 6.0_dp*this%eps6(ti,tj)*tpow)/r - this%linear_force_shift(ti,tj)

  if (.not. (this%smooth_cutoff_width(ti,tj) .feq. 0.0_dp)) then
    IPModel_LJ_pairenergy_deriv = IPModel_LJ_pairenergy_deriv             * poly_switch(r,this%cutoff_a(ti,tj),this%smooth_cutoff_width(ti,tj)) &
                                 +IPModel_LJ_pairenergy(this, ti, tj, r)  * dpoly_switch(r,this%cutoff_a(ti,tj),this%smooth_cutoff_width(ti,tj))

  end if
  
end function IPModel_LJ_pairenergy_deriv

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% XML param reader functions.
!% An example for XML stanza is given below, please notice that
!% they are simply dummy parameters for testing purposes, with no physical meaning.
!%
!%> <LJ_params n_types="2" label="default">
!%> <per_type_data type="1" atomic_num="29" />
!%> <per_type_data type="2" atomic_num="79" />
!%> <per_pair_data type1="1" type2="1" sigma="4.0" eps6="1.0" 
!%>       eps12="1.0" cutoff="6.0" energy_shift="T" linear_force_shift="F" />
!%> <per_pair_data type1="2" type2="2" sigma="5.0" eps6="2.0" 
!%>       eps12="2.0" cutoff="7.5" energy_shift="T" linear_force_shift="F" />
!%> <per_pair_data type1="1" type2="2" sigma="4.5" eps6="1.5" 
!%>       eps12="1.5" cutoff="6.75" energy_shift="T" linear_force_shift="F" />
!%> </LJ_params>
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
subroutine IPModel_startElement_handler(URI, localname, name, attributes)
  character(len=*), intent(in)   :: URI  
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name 
  type(dictionary_t), intent(in) :: attributes

  integer :: status
  character(len=1024) :: value

  logical :: energy_shift, linear_force_shift,smooth_cutoff_width
  integer :: ti, tj

  if (name == 'LJ_params') then ! new LJ stanza

    if (parse_in_ip) &
      call system_abort("IPModel_startElement_handler entered LJ_params with parse_in true. Probably a bug in FoX (4.0.1, e.g.)")

    if (parse_matched_label) return ! we already found an exact match for this label

    call QUIP_FoX_get_value(attributes, 'label', value, status)
    if (status /= 0) value = ''

    if (len(trim(parse_ip%label)) > 0) then ! we were passed in a label
      if (value == parse_ip%label) then ! exact match
	parse_matched_label = .true.
	parse_in_ip = .true.
      else ! no match
	parse_in_ip = .false.
      endif
    else ! no label passed in
      parse_in_ip = .true.
    endif

    if (parse_in_ip) then
      if (parse_ip%n_types /= 0) then
	call finalise(parse_ip)
      endif

      call QUIP_FoX_get_value(attributes, 'n_types', value, status)
      if (status == 0) then
	read (value, *) parse_ip%n_types
      else
	call system_abort("Can't find n_types in LJ_params")
      endif

      call QUIP_FoX_get_value(attributes, 'only_inter_resid', value, status)
      if (status == 0) then
	read (value, *) parse_ip%only_inter_resid
      else
	parse_ip%only_inter_resid = .false.
      endif

      call QUIP_FoX_get_value(attributes, 'tail_corr_factor', value, status)
      if (status == 0) then
        read (value, *) parse_ip%tail_corr_smooth_factor
        parse_ip%do_tail_corrections = .true.
      else
        parse_ip%do_tail_corrections = .false.
      endif

      allocate(parse_ip%atomic_num(parse_ip%n_types))
      parse_ip%atomic_num = 0
      allocate(parse_ip%sigma(parse_ip%n_types,parse_ip%n_types))
      parse_ip%sigma = 1.0_dp
      allocate(parse_ip%eps6(parse_ip%n_types,parse_ip%n_types))
      parse_ip%eps6 = 0.0_dp
      allocate(parse_ip%eps12(parse_ip%n_types,parse_ip%n_types))
      parse_ip%eps12 = 0.0_dp
      allocate(parse_ip%cutoff_a(parse_ip%n_types,parse_ip%n_types))
      parse_ip%cutoff_a = 0.0_dp
      allocate(parse_ip%energy_shift(parse_ip%n_types,parse_ip%n_types))
      allocate(parse_ip%linear_force_shift(parse_ip%n_types,parse_ip%n_types))
      allocate(parse_ip%smooth_cutoff_width(parse_ip%n_types,parse_ip%n_types))
      parse_ip%energy_shift = 0.0_dp
      parse_ip%linear_force_shift = 0.0_dp
      parse_ip%smooth_cutoff_width = 0.0_dp
    endif

  elseif (parse_in_ip .and. name == 'per_type_data') then

    call QUIP_FoX_get_value(attributes, "type", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find type")
    read (value, *) ti

    if (ti < 1) call system_abort("IPModel_LJ_read_params_xml got per_type_data type="//ti//" < 1")
    if (ti > parse_ip%n_types) call system_abort("IPModel_LJ_read_params_xml got per_type_data type="//ti//" > n_types="//parse_ip%n_types)

    call QUIP_FoX_get_value(attributes, "atomic_num", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find atomic_num")
    read (value, *) parse_ip%atomic_num(ti)

    if (allocated(parse_ip%type_of_atomic_num)) deallocate(parse_ip%type_of_atomic_num)
    allocate(parse_ip%type_of_atomic_num(maxval(parse_ip%atomic_num)))
    parse_ip%type_of_atomic_num = 0
    do ti=1, parse_ip%n_types
      if (parse_ip%atomic_num(ti) > 0) &
	parse_ip%type_of_atomic_num(parse_ip%atomic_num(ti)) = ti
    end do

    parse_ip%energy_shift = 0.0_dp
    parse_ip%linear_force_shift = 0.0_dp
    parse_ip%smooth_cutoff_width = 0.0_dp

  elseif (parse_in_ip .and. name == 'per_pair_data') then

    call QUIP_FoX_get_value(attributes, "type1", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find type1")
    read (value, *) ti
    call QUIP_FoX_get_value(attributes, "type2", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find type2")
    read (value, *) tj

    if (ti < 1) call system_abort("IPModel_LJ_read_params_xml got per_type_data type1="//ti//" < 1")
    if (ti > parse_ip%n_types) call system_abort("IPModel_LJ_read_params_xml got per_pair_data type1="//ti//" > n_types="//parse_ip%n_types)
    if (tj < 1) call system_abort("IPModel_LJ_read_params_xml got per_type_data type2="//tj//" < 1")
    if (tj > parse_ip%n_types) call system_abort("IPModel_LJ_read_params_xml got per_pair_data type2="//tj//" > n_types="//parse_ip%n_types)

    call QUIP_FoX_get_value(attributes, "sigma", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find sigma")
    read (value, *) parse_ip%sigma(ti,tj)
    call QUIP_FoX_get_value(attributes, "eps6", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find eps6")
    read (value, *) parse_ip%eps6(ti,tj)
    call QUIP_FoX_get_value(attributes, "eps12", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find eps12")
    read (value, *) parse_ip%eps12(ti,tj)
    call QUIP_FoX_get_value(attributes, "cutoff", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find cutoff")
    read (value, *) parse_ip%cutoff_a(ti,tj)
    
    call QUIP_FoX_get_value(attributes, "energy_shift", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find energy_shift")
    read (value, *) energy_shift
    if (energy_shift) parse_ip%energy_shift(ti,tj) = IPModel_LJ_pairenergy(parse_ip, ti, tj, parse_ip%cutoff_a(ti,tj))
    
    call QUIP_FoX_get_value(attributes, "linear_force_shift", value, status)
    if (status /= 0) call system_abort ("IPModel_LJ_read_params_xml cannot find linear_force_shift")
    read (value, *) linear_force_shift
    if (linear_force_shift) parse_ip%linear_force_shift(ti,tj) = IPModel_LJ_pairenergy_deriv(parse_ip, ti, tj, parse_ip%cutoff_a(ti,tj))

    call QUIP_FoX_get_value(attributes, "smooth_cutoff_width", value, status)
    if (status == 0)  read (value, *) parse_ip%smooth_cutoff_width(ti,tj)

    if (ti /= tj) then
      parse_ip%eps6(tj,ti) = parse_ip%eps6(ti,tj)
      parse_ip%eps12(tj,ti) = parse_ip%eps12(ti,tj)
      parse_ip%sigma(tj,ti) = parse_ip%sigma(ti,tj)
      parse_ip%cutoff_a(tj,ti) = parse_ip%cutoff_a(ti,tj)
      parse_ip%energy_shift(tj,ti) = parse_ip%energy_shift(ti,tj)
      parse_ip%linear_force_shift(tj,ti) = parse_ip%linear_force_shift(ti,tj)
      parse_ip%smooth_cutoff_width(tj,ti) =  parse_ip%smooth_cutoff_width(ti,tj)
    end if

  endif

end subroutine IPModel_startElement_handler

subroutine IPModel_endElement_handler(URI, localname, name)
  character(len=*), intent(in)   :: URI  
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name 

  if (parse_in_ip) then
    if (name == 'LJ_params') then
      parse_in_ip = .false.
    end if
  endif

end subroutine IPModel_endElement_handler

subroutine IPModel_LJ_read_params_xml(this, param_str)
  type(IPModel_LJ), intent(inout), target :: this
  character(len=*), intent(in) :: param_str

  type(xml_t) :: fxml

  if (len(trim(param_str)) <= 0) return

  parse_in_ip = .false.
  parse_matched_label = .false.
  parse_ip => this

  call open_xml_string(fxml, param_str)
  call parse(fxml,  &
    startElement_handler = IPModel_startElement_handler, &
    endElement_handler = IPModel_endElement_handler)
  call close_xml_t(fxml)

  if (this%n_types == 0) then
    call system_abort("IPModel_LJ_read_params_xml parsed file, but n_types = 0")
  endif

end subroutine IPModel_LJ_read_params_xml


!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% Printing of LJ parameters: number of different types, cutoff radius, atomic numbers, etc.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_LJ_Print (this, file)
  type(IPModel_LJ), intent(in) :: this
  type(Inoutput), intent(inout),optional :: file

  integer :: ti, tj

  call Print("IPModel_LJ : Lennard-Jones", file=file)
  call Print("IPModel_LJ : n_types = " // this%n_types // " cutoff = " // this%cutoff // &
      " only_inter_resid = " // this%only_inter_resid // " do_tail_corrections = " // this%do_tail_corrections, file=file)

  do ti=1, this%n_types
    call Print ("IPModel_LJ : type " // ti // " atomic_num " // this%atomic_num(ti), file=file)
    call verbosity_push_decrement()
    do tj=1, this%n_types
      call Print ("IPModel_LJ : interaction " // ti // " " // tj // " sigma " // this%sigma(ti,tj) // " eps6,12 " // &
	this%eps6(ti,tj) // " " // this%eps12(ti,tj) // " cutoff_a " // this%cutoff_a(ti,tj) // " energy_shift " // &
	this%energy_shift(ti,tj) // " linear_force_shift " // this%linear_force_shift(ti,tj) // &
        " smooth_cutoff_width " // this%smooth_cutoff_width(ti,tj) , file=file)
    end do
    call verbosity_pop()
  end do

end subroutine IPModel_LJ_Print

function parse_extra_calcs(args_str, extra_calcs_list) result(n_extra_calcs)
  character(len=*), intent(in) :: args_str
  character(len=*), intent(out) :: extra_calcs_list(:)
  integer :: n_extra_calcs

  character(len=STRING_LENGTH) :: extra_calcs_str
  type(Dictionary) :: params

  n_extra_calcs = 0
  call initialise(params)
  call param_register(params, "extra_calcs", "", extra_calcs_str, help_string="No help yet.  This source file was $LastChangedBy$")
  if (param_read_line(params, args_str, ignore_unknown=.true.,task='parse_extra_calcs')) then
    if (len_trim(extra_calcs_str) > 0) then
      call split_string_simple(extra_calcs_str, extra_calcs_list, n_extra_calcs, ":")
    end if
  end if
  call finalise(params)

end function parse_extra_calcs

end module IPModel_LJ_module

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
!X IPModel_Brenner_Screened module  
!X
!% Module for interfacing to Screened Brenner Potential as described in
!%
!% ``Describing bond-breaking processes by reactive potentials: 
!%   Importance of an environment-dependent interaction range.''
!% Lars Pastewka, Pablo Pou, Rub�n P�rez, Peter Gumbsch, Michael Moseler.
!% Phys. Rev. B (2008) vol. 78 (16) pp. 4
!% http://dx.doi.org/10.1103/PhysRevB.78.161402
!%
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
#include "error.inc"

module IPModel_Brenner_Screened_module

use error_module
use system_module, only : dp, inoutput, print, verbosity_push_decrement, verbosity_pop, operator(//)
use dictionary_module
use paramreader_module
use linearalgebra_module
use atoms_types_module
use atoms_module

use mpi_context_module
use QUIP_Common_module

#ifdef HAVE_MDCORE
use force_brenner2002_exp, only: force_brenner2002_exp_kernel
use db_brenner2002_exp, only: with_dihedral, db_brenner2002_init
#endif

implicit none
private

include 'IPModel_interface.h'

public :: IPModel_Brenner_Screened
type IPModel_Brenner_Screened
  integer :: n_types = 0
  integer, allocatable :: atomic_num(:), type_of_atomic_num(:)

  real(dp) :: cutoff = 0.0_dp

  integer     ::  n
  type(Atoms) :: at
  integer, allocatable, dimension(:)  :: aptr
  integer, allocatable, dimension(:)  :: bptr
  integer     :: bptr_num

  character(len=STRING_LENGTH) :: label

end type IPModel_Brenner_Screened

logical, private :: parse_in_ip, parse_matched_label
type(IPModel_Brenner_Screened), private, pointer :: parse_ip

interface Initialise
  module procedure IPModel_Brenner_Screened_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_Brenner_Screened_Finalise
end interface Finalise

interface Print
  module procedure IPModel_Brenner_Screened_Print
end interface Print

interface Calc
  module procedure IPModel_Brenner_Screened_Calc
end interface Calc

contains

subroutine IPModel_Brenner_Screened_Initialise_str(this, args_str, param_str)
  type(IPModel_Brenner_Screened), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str

  type(Dictionary) :: params
  character(len=STRING_LENGTH) label

  call Finalise(this)

  call initialise(params)
  this%label=''
  call param_register(params, 'label', '', this%label, help_string="No help yet.  This source file was $LastChangedBy$")
  if (.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_Brenner_Screened_Initialise_str args_str')) then
    call system_abort("IPModel_Brenner_Screened_Initialise_str failed to parse label from args_str="//trim(args_str))
  endif
  call finalise(params)

  call IPModel_Brenner_Screened_read_params_xml(this, param_str)

#ifdef HAVE_MDCORE
  with_dihedral = 0
  call db_brenner2002_init()
  this%cutoff = 4.0_dp
#else
  call system_abort('IPModel_Brenner_Screened_Initialise - support for mdcore not compiled in')
#endif 

end subroutine IPModel_Brenner_Screened_Initialise_str

subroutine IPModel_Brenner_Screened_Finalise(this)
  type(IPModel_Brenner_Screened), intent(inout) :: this

  if (allocated(this%atomic_num)) deallocate(this%atomic_num)
  if (allocated(this%type_of_atomic_num)) deallocate(this%type_of_atomic_num)

  this%n_types = 0
  this%label = ''
end subroutine IPModel_Brenner_Screened_Finalise


subroutine IPModel_Brenner_Screened_Calc(this, at, e, local_e, f, virial, local_virial, args_str, mpi, error)
   type(IPModel_Brenner_Screened), intent(inout):: this
   type(Atoms), intent(inout)      :: at   !Active + buffer atoms
   real(dp), intent(out), optional :: e, local_e(:)
   real(dp), intent(out), optional :: f(:,:), local_virial(:,:)   !% Forces, dimensioned as \texttt{f(3,at%N)}, local virials, dimensioned as \texttt{local_virial(9,at%N)} 
   real(dp), intent(out), optional :: virial(3,3)
   character(len=*), optional      :: args_str
   type(MPI_Context), intent(in), optional :: mpi
   integer, intent(out), optional :: error

   integer:: i,n
   real(dp), dimension(:,:), allocatable :: pos_in, force_out, dr
   real(dp) :: brenner_e, brenner_virial(3,3)
    
   real(dp), dimension(:), allocatable :: abs_dr
   integer, dimension(:), allocatable :: aptr, bptr, k_typ
   integer :: n_tot, neighb

   type(Dictionary)                :: params
   logical :: has_atom_mask_name
   character(STRING_LENGTH) :: atom_mask_name
   real(dp) :: r_scale, E_scale
   logical :: do_rescale_r, do_rescale_E

   INIT_ERROR(error)

   if (present(e)) e = 0.0_dp
   if (present(local_e)) then
      call check_size('Local_E',local_e,(/at%N/),'IPModel_Brenner_Screened_Calc', error)
      local_e = 0.0_dp
   endif
   if (present(f)) then
      call check_size('Force',f,(/3,at%Nbuffer/),'IPModel_Brenner_Screened_Calc', error)
      f = 0.0_dp
   end if
   if (present(virial)) virial = 0.0_dp
   if (present(local_virial)) then
      call check_size('Local_virial',local_virial,(/9,at%Nbuffer/),'IPModel_Brenner_Screened_Calc', error)
      local_virial = 0.0_dp
      RAISE_ERROR("IPModel_Brenner_Screened_Calc: local_virial calculation requested but not supported yet.", error)
   endif

   if (present(args_str)) then
      call initialise(params)
      call param_register(params, 'atom_mask_name', 'NONE', atom_mask_name, has_value_target=has_atom_mask_name, help_string="No help yet.  This source file was $LastChangedBy$")
      call param_register(params, 'r_scale', '1.0',r_scale, has_value_target=do_rescale_r, help_string="Recaling factor for distances. Default 1.0.")
      call param_register(params, 'E_scale', '1.0',E_scale, has_value_target=do_rescale_E, help_string="Recaling factor for energy. Default 1.0.")

      if(.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_Brenner_Screened_Calc args_str')) then
         RAISE_ERROR("IPModel_Brenner_Screened_Calc failed to parse args_str='"//trim(args_str)//"'", error)
      endif
      call finalise(params)
      if(has_atom_mask_name) then
         RAISE_ERROR('IPModel_Brenner_Screened_Calc: atom_mask_name found, but not supported', error)
      endif
      if (do_rescale_r .or. do_rescale_E) then
         RAISE_ERROR("IPModel_Brenner_Screened_Calc: rescaling of potential with r_scale and E_scale not yet implemented!", error)
      end if

   endif

   n_tot = 0
   do i=1,at%N
      n_tot = n_tot + n_neighbours(at, i)
   end do

   allocate(aptr(at%N+1),bptr(n_tot+at%n+1),dr(n_tot+at%n+1,3), abs_dr(n_tot+at%n+1), &
        pos_in(at%n,3),force_out(at%n,3),k_typ(at%N))
   force_out = 0.0_dp
   dr = 0.0_dp
   brenner_e = 0.0_dp
   aptr = 0
   bptr = 0 

   k_typ = 1

   neighb = 1
   do i=1,at%N
      pos_in(i,:) = at%pos(:,i)
      
      aptr(i) = neighb
      do n=1,n_neighbours(at,i)
         bptr(neighb) = neighbour(at,i,n, diff=dr(neighb,:),distance=abs_dr(neighb))
         dr(neighb,:) = -dr(neighb,:) ! opposite sign convention

         neighb = neighb + 1
      end do
      neighb = neighb + 1
   end do
   bptr(neighb) = 0
   aptr(at%N+1) = neighb

   brenner_virial = 0.0_dp
#ifdef HAVE_MDCORE
   call force_brenner2002_exp_kernel(at%N,pos_in,k_typ,brenner_e,force_out, brenner_virial, &
        aptr, bptr, size(bptr), dr, abs_dr)
#else
   call system_abort('IPModel_Brenner_Screened - mdcore support not compiled in')
#endif

   if (present(local_e)) call system_abort('IPModel_Brenner_Screened - no support for local energies')

   if (present(e)) e = brenner_e
   
   if (present(f)) then
      do i=1,at%N
         f(:,i) = force_out(i,:)
      end do
   end if
   
   if (present(virial)) then
      virial = -brenner_virial
   end if
   
   deallocate(aptr,bptr,dr,pos_in,force_out,abs_dr)

end subroutine IPModel_Brenner_Screened_Calc


subroutine IPModel_Brenner_Screened_Print(this, file)
  type(IPModel_Brenner_Screened), intent(in) :: this
  type(Inoutput), intent(inout),optional :: file

  integer :: ti, tj

  call Print("IPModel_Brenner_Screened : Screnned Brenner Potential", file=file)
  call Print(" Phys. Rev. B (2008) vol. 78 (16) pp. 4 ", file=file)
  call Print("IPModel_Brenner_Screened : n_types = " // this%n_types // " cutoff = " // this%cutoff, file=file)

  do ti=1, this%n_types
    call Print ("IPModel_Brenner_Screened : type " // ti // " atomic_num " // this%atomic_num(ti), file=file)
    call verbosity_push_decrement()
    call Print ("IPModel_Brenner_Screened : " // &
        "cutoff " // this%cutoff , &
         file=file)
    call verbosity_pop()
  end do

end subroutine IPModel_Brenner_Screened_Print

subroutine IPModel_Brenner_Screened_read_params_xml(this, param_str)
  type(IPModel_Brenner_Screened), intent(inout), target :: this
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
    call system_abort("IPModel_Brenner_Screened_read_params_xml parsed file, but n_types = 0")
  endif

end subroutine IPModel_Brenner_Screened_read_params_xml

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% XML param reader functions
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
subroutine IPModel_startElement_handler(URI, localname, name, attributes)
  character(len=*), intent(in)   :: URI
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name
  type(dictionary_t), intent(in) :: attributes

  integer :: status
  character(len=STRING_LENGTH) :: value

  logical shifted
  integer ti, tj

  if (name == 'Brenner_Screened_params') then ! new Brenner_Screened stanza

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
        call system_abort("Can't find n_types in Brenner_Screened_params")
      endif

      allocate(parse_ip%atomic_num(parse_ip%n_types))
      parse_ip%atomic_num = 0

      call QUIP_FoX_get_value(attributes, "cutoff", value, status)
      if (status /= 0) call system_abort ("IPModel_Brenner_Screened_read_params_xml cannot find cutoff")
      read (value, *) parse_ip%cutoff
    endif


  elseif (parse_in_ip .and. name == 'per_type_data') then

    call QUIP_FoX_get_value(attributes, "type", value, status)
    if (status /= 0) call system_abort ("IPModel_Brenner_Screened_read_params_xml cannot find type")
    read (value, *) ti

    call QUIP_FoX_get_value(attributes, "atomic_num", value, status)
    if (status /= 0) call system_abort ("IPModel_Brenner_Screened_read_params_xml cannot find atomic_num")
    read (value, *) parse_ip%atomic_num(ti)

    if (allocated(parse_ip%type_of_atomic_num)) deallocate(parse_ip%type_of_atomic_num)
    allocate(parse_ip%type_of_atomic_num(maxval(parse_ip%atomic_num)))
    parse_ip%type_of_atomic_num = 0
    do ti=1, parse_ip%n_types
      if (parse_ip%atomic_num(ti) > 0) &
        parse_ip%type_of_atomic_num(parse_ip%atomic_num(ti)) = ti
    end do


  endif

end subroutine IPModel_startElement_handler

subroutine IPModel_endElement_handler(URI, localname, name)
  character(len=*), intent(in)   :: URI
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name

  if (parse_in_ip) then
    if (name == 'Brenner_Screened_params') then
      parse_in_ip = .false.
    end if
  endif

end subroutine IPModel_endElement_handler

end module IPModel_Brenner_Screened_module

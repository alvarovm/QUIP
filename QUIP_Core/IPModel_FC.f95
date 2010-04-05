!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X
!X     QUIP: quantum mechanical and interatomic potential simulation package
!X     
!X     Portions written by Noam Bernstein, while working at the
!X     Naval Research Laboratory, Washington DC. 
!X
!X     Portions written by Gabor Csanyi, Copyright 2006-2007.   
!X
!X     When using this software,  please cite the following reference:
!X
!X     reference
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X
!X IPModel_FC module  
!X
!% Module for Force-Constant (Guggenheim-McGlashan) pair potential.
!% \begin{equation} 
!%   \nonumber
!%     V(r) = 1/2 phi2 (r-r0)^2 + 1/6 phi3 (r-r0)^3 + 1.24 phi4 (r-r0)^4
!% \end{equation} 
!% 
!% Proc. Royal Soc. London A, v. 255, p. 456 (1960)
!% Used, e.g. by Bernstein, Feldman, and Singh, Phys. Rev. B (2010)
!%
!% The IPModel_FC object contains all the parameters read from a
!% 'FC_params' XML stanza.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
module IPModel_FC_module

use libatoms_module

use mpi_context_module
use QUIP_Common_module

implicit none

private 

include 'IPModel_interface.h'

public :: IPModel_FC
type IPModel_FC
  integer :: n_types = 0         !% Number of atomic types. 
  integer, allocatable :: atomic_num(:), type_of_atomic_num(:)  !% Atomic number dimensioned as \texttt{n_types}. 

  real(dp) :: cutoff = 0.0_dp    !% Cutoff for computing connection.

  real(dp), allocatable :: r0(:,:,:), phi2(:,:,:), phi3(:,:,:), phi4(:,:,:) !% IP parameters.
  integer, allocatable :: n_fcs(:,:)

  character(len=FIELD_LENGTH) :: ideal_struct_file
  type(Atoms) :: ideal_struct

  character(len=FIELD_LENGTH) label
  type(mpi_context) :: mpi

end type IPModel_FC

logical :: parse_in_ip, parse_matched_label
type(IPModel_FC), pointer :: parse_ip

interface Initialise
  module procedure IPModel_FC_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_FC_Finalise
end interface Finalise

interface Print
  module procedure IPModel_FC_Print
end interface Print

interface Calc
  module procedure IPModel_FC_Calc
end interface Calc

contains

subroutine IPModel_FC_Initialise_str(this, args_str, param_str, mpi)
  type(IPModel_FC), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str
  type(mpi_context), intent(in), optional :: mpi

  type(Dictionary) :: params
  integer, allocatable :: sorted_index(:)
  real(dp), allocatable :: t_phi(:)
  integer :: ti, tj

  call Finalise(this)

  call initialise(params)
  this%label = ''
  call param_register(params, 'label', '', this%label)
  call param_register(params, "ideal_struct_file", PARAM_MANDATORY, this%ideal_struct_file)
  if (.not. param_read_line(params, args_str, ignore_unknown=.true.,do_check=.true.,task='IPModel_FC_Initialise_str args_str')) then
    call system_abort("IPModel_FC_Initialise_str failed to find mandatory ideal_struct_file or parse label from args_str="//trim(args_str))
  endif
  call finalise(params)

  call IPModel_FC_read_params_xml(this, param_str)

  call atoms_read_xyz_filename(this%ideal_struct, trim(this%ideal_struct_file))

  do ti=1, this%n_types
  do tj=1, this%n_types
    this%n_fcs(ti,tj) = count(this%r0(ti,tj,:) > 0.0_dp)
    if (this%n_fcs(ti,tj) > 1) then
      allocate(sorted_index(this%n_fcs(ti,tj)))
      allocate(t_phi(this%n_fcs(ti,tj)))
      call insertion_sort(this%r0(ti,tj,1:this%n_fcs(ti,tj)), sorted_index)
      t_phi = this%phi2(ti,tj,sorted_index); this%phi2(ti,tj,1:this%n_fcs(ti,tj)) = t_phi
      t_phi = this%phi3(ti,tj,sorted_index); this%phi3(ti,tj,1:this%n_fcs(ti,tj)) = t_phi
      t_phi = this%phi4(ti,tj,sorted_index); this%phi4(ti,tj,1:this%n_fcs(ti,tj)) = t_phi
      deallocate(sorted_index)
      deallocate(t_phi)
    endif
  end do
  end do

  if (present(mpi)) this%mpi = mpi

end subroutine IPModel_FC_Initialise_str

subroutine IPModel_FC_Finalise(this)
  type(IPModel_FC), intent(inout) :: this

  if (allocated(this%atomic_num)) deallocate(this%atomic_num)
  if (allocated(this%type_of_atomic_num)) deallocate(this%type_of_atomic_num)

  if (allocated(this%r0)) deallocate(this%r0)
  if (allocated(this%phi2)) deallocate(this%phi2)
  if (allocated(this%phi3)) deallocate(this%phi3)
  if (allocated(this%phi4)) deallocate(this%phi4)

  this%n_types = 0
  this%label = ''
end subroutine IPModel_FC_Finalise

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% The potential calculator: this routine computes energy, forces and the virial.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_FC_Calc(this, at, e, local_e, f, virial, args_str)
  type(IPModel_FC), intent(inout) :: this
  type(Atoms), intent(inout) :: at
  real(dp), intent(out), optional :: e, local_e(:) !% \texttt{e} = System total energy, \texttt{local_e} = energy of each atom, vector dimensioned as \texttt{at%N}.  
  real(dp), intent(out), optional :: f(:,:)        !% Forces, dimensioned as \texttt{f(3,at%N)} 
  real(dp), intent(out), optional :: virial(3,3)   !% Virial
  character(len=*), intent(in), optional      :: args_str

  real(dp), pointer :: w_e(:)
  integer i, ji, j, ti, tj, fc_i
  real(dp) :: dr(3), dr_mag, ideal_dr_mag
  real(dp) :: de, de_dr
  integer :: s(3)
  logical :: i_is_min_image

  integer :: i_calc, n_extra_calcs
  character(len=20) :: extra_calcs_list(10)

  logical :: do_flux = .false.
  real(dp), pointer :: velo(:,:)
  real(dp) :: flux(3)

  if (present(e)) e = 0.0_dp
  if (present(local_e)) local_e = 0.0_dp
  if (present(virial)) virial = 0.0_dp
  if (present(f)) then 
     if(size(f,1) .ne. 3 .or. size(f,2) .ne. at%N) call system_abort('IPMOdel_FC_Calc: f is the wrong size')
     f = 0.0_dp
  end if

  if (present(args_str)) then
    if (len_trim(args_str) > 0) then
      n_extra_calcs = parse_extra_calcs(args_str, extra_calcs_list)
      if (n_extra_calcs > 0) then
	do i_calc=1, n_extra_calcs
	  select case(trim(extra_calcs_list(i_calc)))
	    case("flux")
	      if (.not. assign_pointer(at, "velo", velo)) &
		call system_abort("IPModel_FC_Calc Flux calculation requires velo field")
	      do_flux = .true.
	      flux = 0.0_dp
	    case default
	      call system_abort("Unsupported extra_calc '"//trim(extra_calcs_list(i_calc))//"'")
	  end select
	end do
      endif ! n_extra_calcs
    endif ! len_trim(args_str)
  endif ! present(args_str)

  if (.not. assign_pointer(at, "weight", w_e)) nullify(w_e)

  do i = 1, at%N
    i_is_min_image = is_min_image(at,i)

    if (this%mpi%active) then
      if (mod(i-1, this%mpi%n_procs) /= this%mpi%my_proc) cycle
    endif

    do ji = 1, atoms_n_neighbours(at, i)
      j = atoms_neighbour(at, i, ji, dr_mag, cosines = dr, shift=s)
      
      if (dr_mag .feq. 0.0_dp) cycle
      if ((i < j) .and. i_is_min_image) cycle

      ti = get_type(this%type_of_atomic_num, at%Z(i))
      tj = get_type(this%type_of_atomic_num, at%Z(j))

      ! NB: This is right only if ideal_struct%travel is 0.
      !     We are not subtracting ideal_struct%travel because is does not have the 
      !     component travel initialised
      ! v = (p(j) - lat . travel(j))  - (p(i) - lat . travel(i)) + lat. s
      !   = p(j) - p(i) + lat . (travel(i) - travel(j) + s)
      ideal_dr_mag = norm( this%ideal_struct%pos(:,j) - this%ideal_struct%pos(:,i) + &
			   (this%ideal_struct%lattice .mult. (at%travel(:,i) - at%travel(:,j) + s)) )
      fc_i = find_fc_i(this, ti, tj, ideal_dr_mag)
      if (fc_i <= 0) cycle

      if (present(e) .or. present(local_e)) then
	de = IPModel_FC_pairenergy(this, ti, tj, fc_i, dr_mag)
	if (present(local_e)) then
	  local_e(i) = local_e(i) + 0.5_dp*de
          if(i_is_min_image) local_e(j) = local_e(j) + 0.5_dp*de
	endif
	if (present(e)) then
	  if (associated(w_e)) then
	    de = de*0.5_dp*(w_e(i)+w_e(j))
	  endif
          if(i_is_min_image) then
             e = e + de
          else
             e = e + 0.5_dp*de
          endif
	endif
      endif
      if (present(f) .or. present(virial) .or. do_flux) then
	de_dr = IPModel_FC_pairenergy_deriv(this, ti, tj, fc_i, dr_mag)
	if (associated(w_e)) then
	  de_dr = de_dr*0.5_dp*(w_e(i)+w_e(j))
	endif
	if (present(f)) then
	  f(:,i) = f(:,i) + de_dr*dr
	  if(i_is_min_image) f(:,j) = f(:,j) - de_dr*dr
	endif
	if (do_flux) then
	  ! -0.5 (v_i + v_j) . F_ij * dr_ij
	  flux = flux - 0.5_dp*sum((velo(:,i)+velo(:,j))*(de_dr*dr))*(dr*dr_mag)
	endif
	if (present(virial)) then
	  if(i_is_min_image) then
             virial = virial - de_dr*(dr .outer. dr)*dr_mag
          else
             virial = virial - 0.5_dp*de_dr*(dr .outer. dr)*dr_mag
          endif
	endif
      endif
    end do
  end do ! i

  if (present(e)) e = sum(this%mpi, e)
  if (present(local_e)) call sum_in_place(this%mpi, local_e)
  if (present(virial)) call sum_in_place(this%mpi, virial)
  if (present(f)) call sum_in_place(this%mpi, f)
  if (do_flux) then
    flux = flux / cell_volume(at)
    call sum_in_place(this%mpi, flux)
    call set_value(at%params, "Flux", flux)
  endif

end subroutine IPModel_FC_Calc

!% This routine computes the two-body term for a pair of atoms  separated by a distance r.
function IPModel_FC_pairenergy(this, ti, tj, fc_i, r)
  type(IPModel_FC), intent(in) :: this
  integer, intent(in) :: ti, tj   !% Atomic types.
  integer, intent(in) :: fc_i    !% Force-constant index
  real(dp), intent(in) :: r       !% Distance.
  real(dp) :: IPModel_FC_pairenergy

  real(dp) :: dr, dr2, dr3, dr4
  real(dp), parameter :: c2 = 1.0_dp/2.0_dp, c3 = 1.0_dp/6.0_dp, c4 = 1.0_dp/24.0_dp

  if ((r .feq. 0.0_dp) .or. (r > this%cutoff)) then
    IPModel_FC_pairenergy = 0.0
    return
  endif

  dr = r - this%r0(ti,tj,fc_i)
  dr2 = dr*dr
  dr3 = dr2*dr
  dr4 = dr2*dr2
  IPModel_FC_pairenergy = c2*this%phi2(ti,tj,fc_i)*dr2 + &
			  c3*this%phi3(ti,tj,fc_i)*dr3 + &
			  c4*this%phi4(ti,tj,fc_i)*dr4
end function IPModel_FC_pairenergy

!% Derivative of the two-body term.
function IPModel_FC_pairenergy_deriv(this, ti, tj, fc_i, r)
  type(IPModel_FC), intent(in) :: this
  integer, intent(in) :: ti, tj   !% Atomic types.
  integer, intent(in) :: fc_i     !% FC index
  real(dp), intent(in) :: r       !% Distance.
  real(dp) :: IPModel_FC_pairenergy_deriv

  real(dp) :: dr, dr2, dr3
  real(dp), parameter :: c2 = 1.0_dp, c3 = 1.0_dp/2.0_dp, c4 = 1.0_dp/6.0_dp

  if ((r .feq. 0.0_dp) .or. (r > this%cutoff)) then
    IPModel_FC_pairenergy_deriv = 0.0
    return
  endif

  dr = r - this%r0(ti,tj,fc_i)
  dr2 = dr*dr
  dr3 = dr2*dr
  IPModel_FC_pairenergy_deriv = c2*this%phi2(ti,tj,fc_i)*dr + &
				c3*this%phi3(ti,tj,fc_i)*dr2 + &
				c4*this%phi4(ti,tj,fc_i)*dr3
end function IPModel_FC_pairenergy_deriv

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% XML param reader functions.
!% An example for XML stanza is given below, please notice that
!% they are simply dummy parameters for testing purposes, with no physical meaning.
!%
!%> <FC_params n_types="2" label="default">
!%> <per_type_data type="1" atomic_num="29" />
!%> <per_type_data type="2" atomic_num="79" />
!%> <per_pair_data type1="1" type2="1" sigma="4.0" eps6="1.0" 
!%>       eps12="1.0" cutoff="6.0" shifted="T" />
!%> <per_pair_data type1="2" type2="2" sigma="5.0" eps6="2.0" 
!%>       eps12="2.0" cutoff="7.5" shifted="T" />
!%> <per_pair_data type1="1" type2="2" sigma="4.5" eps6="1.5" 
!%>       eps12="1.5" cutoff="6.75" shifted="T" />
!%> </FC_params>
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
subroutine IPModel_startElement_handler(URI, localname, name, attributes)
  character(len=*), intent(in)   :: URI  
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name 
  type(dictionary_t), intent(in) :: attributes

  integer :: status
  character(len=1024) :: value

  integer atnum_i, atnum_j, fc_i, ti, tj, max_n_fcs, ti_a(1)

  if (name == 'FC_params') then ! new FC stanza
    if (parse_in_ip) &
      call system_abort("IPModel_startElement_handler entered FC_params with parse_in true. Probably a bug in FoX (4.0.1, e.g.)")

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
	read (value, *), parse_ip%n_types
      else
	call system_abort("Can't find n_types in FC_params")
      endif

      call QUIP_FoX_get_value(attributes, 'max_n_fcs', value, status)
      if (status == 0) then
	read (value, *), max_n_fcs
      else
	call system_abort("Can't find max_n_fcs in FC_params")
      endif

      call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
      if (status == 0) then
	read (value, *), parse_ip%cutoff
      else
	call system_abort("Can't find this%cutoff in FC_params")
      endif

      allocate(parse_ip%atomic_num(parse_ip%n_types))
      parse_ip%atomic_num = 0
      allocate(parse_ip%r0(parse_ip%n_types,parse_ip%n_types,max_n_fcs))
      allocate(parse_ip%phi2(parse_ip%n_types,parse_ip%n_types,max_n_fcs))
      allocate(parse_ip%phi3(parse_ip%n_types,parse_ip%n_types,max_n_fcs))
      allocate(parse_ip%phi4(parse_ip%n_types,parse_ip%n_types,max_n_fcs))
      allocate(parse_ip%n_fcs(parse_ip%n_types,parse_ip%n_types))

      parse_ip%r0 = 0.0_dp
      parse_ip%phi2 = 0.0_dp
      parse_ip%phi3 = 0.0_dp
      parse_ip%phi4 = 0.0_dp

    endif ! parse_in_ip
  elseif (parse_in_ip .and. name == 'FC') then

    call QUIP_FoX_get_value(attributes, "atnum_i", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find atnum_i")
    read (value, *) atnum_i
    call QUIP_FoX_get_value(attributes, "atnum_j", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find atnum_j")
    read (value, *) atnum_j
    call QUIP_FoX_get_value(attributes, "fc_i", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find fc_i")
    read (value, *) fc_i

    if (all(parse_ip%atomic_num /= atnum_i)) then
      ti_a = minloc(parse_ip%atomic_num)
      parse_ip%atomic_num(ti_a(1)) = atnum_i
    endif
    if (all(parse_ip%atomic_num /= atnum_j)) then
      ti_a = minloc(parse_ip%atomic_num)
      parse_ip%atomic_num(ti_a(1)) = atnum_j
    endif
    if (allocated(parse_ip%type_of_atomic_num)) deallocate(parse_ip%type_of_atomic_num)
    allocate(parse_ip%type_of_atomic_num(maxval(parse_ip%atomic_num)))
    parse_ip%type_of_atomic_num = 0
    do ti=1, parse_ip%n_types
      if (parse_ip%atomic_num(ti) > 0) &
	parse_ip%type_of_atomic_num(parse_ip%atomic_num(ti)) = ti
    end do

    ti = parse_ip%type_of_atomic_num(atnum_i)
    tj = parse_ip%type_of_atomic_num(atnum_j)

    call QUIP_FoX_get_value(attributes, "r0", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find r0")
    read (value, *) parse_ip%r0(ti,tj,fc_i)
    call QUIP_FoX_get_value(attributes, "phi2", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find phi2")
    read (value, *) parse_ip%phi2(ti,tj,fc_i)
    call QUIP_FoX_get_value(attributes, "phi3", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find phi3")
    read (value, *) parse_ip%phi3(ti,tj,fc_i)
    call QUIP_FoX_get_value(attributes, "phi4", value, status)
    if (status /= 0) call system_abort ("IPModel_FC_read_params_xml cannot find phi4")
    read (value, *) parse_ip%phi4(ti,tj,fc_i)

    if (ti /= tj) then
      parse_ip%r0(tj,ti,fc_i) = parse_ip%r0(ti,tj,fc_i)
      parse_ip%phi2(tj,ti,fc_i) = parse_ip%phi2(ti,tj,fc_i)
      parse_ip%phi3(tj,ti,fc_i) = parse_ip%phi3(ti,tj,fc_i)
      parse_ip%phi4(tj,ti,fc_i) = parse_ip%phi4(ti,tj,fc_i)
    endif

  endif ! parse_in_ip .and. name = 'FC'

end subroutine IPModel_startElement_handler

subroutine IPModel_endElement_handler(URI, localname, name)
  character(len=*), intent(in)   :: URI  
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name 

  if (parse_in_ip) then
    if (name == 'FC_params') then
      parse_in_ip = .false.
    end if
  endif

end subroutine IPModel_endElement_handler

subroutine IPModel_FC_read_params_xml(this, param_str)
  type(IPModel_FC), intent(inout), target :: this
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
    call system_abort("IPModel_FC_read_params_xml parsed file, but n_types = 0")
  endif

end subroutine IPModel_FC_read_params_xml


!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% Printing of FC parameters: number of different types, cutoff radius, atomic numbers, etc.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_FC_Print (this, file)
  type(IPModel_FC), intent(inout) :: this
  type(Inoutput), intent(inout),optional :: file

  integer :: ti, tj, fc_i

  call Print("IPModel_FC : Force-Constant (Guggenheim-McGlashan)", file=file)
  call Print("IPModel_FC : n_types = " // this%n_types // " cutoff = " // this%cutoff, file=file)

  do ti=1, this%n_types
    call Print ("IPModel_FC : type " // ti // " atomic_num " // this%atomic_num(ti), file=file)
    call verbosity_push_decrement()
    do tj=1, this%n_types
      do fc_i=1, this%n_fcs(ti,tj)
	call Print ("IPModel_FC : interaction " // ti // " " // tj // " r0 " // this%r0(ti,tj,fc_i) // " phi2,3,4 " // &
	  this%phi2(ti,tj,fc_i) // " " // this%phi3(ti,tj,fc_i) // " " // this%phi4(ti,tj,fc_i), file=file)
      end do
    end do
    call verbosity_pop()
  end do

  call verbosity_push_decrement(NERD)
  call print("IPModel_FC : ideal_struct_file='"//trim(this%ideal_struct_file)//"'", file=file)
  call print("IPModel_FC : ideal_struct", file=file)
  call print_xyz(this%ideal_struct,xyzfile=file)
  call verbosity_pop()

end subroutine IPModel_FC_Print

function parse_extra_calcs(args_str, extra_calcs_list) result(n_extra_calcs)
  character(len=*), intent(in) :: args_str
  character(len=*), intent(out) :: extra_calcs_list(:)
  integer :: n_extra_calcs

  character(len=FIELD_LENGTH) :: extra_calcs_str
  type(Dictionary) :: params

  n_extra_calcs = 0
  call initialise(params)
  call param_register(params, "extra_calcs", "", extra_calcs_str)
  if (param_read_line(params, args_str, ignore_unknown=.true.,task='parse_extra_calcs')) then
    if (len_trim(extra_calcs_str) > 0) then
      call split_string_simple(extra_calcs_str, extra_calcs_list, n_extra_calcs, ":")
    end if
  end if
  call finalise(params)

end function parse_extra_calcs

function find_fc_i(this, ti, tj, ideal_dr_mag)
  type(IPModel_FC), intent(in) :: this
  integer, intent(in) :: ti, tj
  real(dp), intent(in) :: ideal_dr_mag
  integer find_fc_i

  integer :: fc_i

  find_fc_i = 0
  do fc_i=1, this%n_fcs(ti,tj)
    if (abs(this%r0(ti,tj,fc_i)-ideal_dr_mag) < 1.0e-4_dp) then
      find_fc_i = fc_i
      return
    endif
  end do
end function find_fc_i

end module IPModel_FC_module

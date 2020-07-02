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
!X  Thermostat module
!X
!% This module contains the implementations for all the thermostats available
!% in libAtoms: Langevin, Nose-Hoover and Nose-Hoover-Langevin. 
!% Each thermostat has its own section in the 'thermostat_pre_vel1-4' subroutines,
!% which interleave the usual velocity verlet steps.
!%
!% All Langevin variants with $Q > 0$ are open Langevin, from Jones \& Leimkuhler 
!% preprint ``Adaptive Stochastic Methods for Nonequilibrium Sampling"
!%
!% Langevin steps for THERMOSTAT_ALL_PURPOSE use Ornstein-Uhlenbeck steps as
!% recommended by B. Leimkuhler, private comm.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

module thermostat_module

  use system_module
  use units_module
  use linearalgebra_module
  use atoms_types_module
  use atoms_module

  implicit none
  private

  public :: thermostat, initialise, finalise, print, add_thermostat, remove_thermostat, add_thermostats, update_thermostat, &
       set_degrees_of_freedom, nose_hoover_mass, thermostat_array_assignment
  public :: THERMOSTAT_NONE, &
	    THERMOSTAT_LANGEVIN, &
	    THERMOSTAT_NOSE_HOOVER, &
	    THERMOSTAT_NOSE_HOOVER_LANGEVIN, &
	    THERMOSTAT_LANGEVIN_NPT, &
	    THERMOSTAT_LANGEVIN_PR, &
	    THERMOSTAT_NPH_ANDERSEN, &
	    THERMOSTAT_NPH_PR, &
	    THERMOSTAT_LANGEVIN_OU, &
	    THERMOSTAT_LANGEVIN_NPT_NB, &
	    THERMOSTAT_ALL_PURPOSE
  public :: MIN_TEMP

  public :: thermostat_pre_vel1, thermostat_post_vel1_pre_pos, thermostat_post_pos_pre_calc, thermostat_post_calc_pre_vel2, thermostat_post_vel2

  real(dp), dimension(3,3), parameter :: matrix_one = reshape( (/ 1.0_dp, 0.0_dp, 0.0_dp, &
                                                                & 0.0_dp, 1.0_dp, 0.0_dp, &
                                                                & 0.0_dp, 0.0_dp, 1.0_dp/), (/3,3/) )

  real(dp), parameter :: MIN_TEMP = 1.0_dp ! K

  integer, parameter :: THERMOSTAT_NONE                 = 0, &
                        THERMOSTAT_LANGEVIN             = 1, &
                        THERMOSTAT_NOSE_HOOVER          = 2, &
                        THERMOSTAT_NOSE_HOOVER_LANGEVIN = 3, &
                        THERMOSTAT_LANGEVIN_NPT         = 4, &
                        THERMOSTAT_LANGEVIN_PR          = 5, &
                        THERMOSTAT_NPH_ANDERSEN         = 6, &
                        THERMOSTAT_NPH_PR               = 7, &
                        THERMOSTAT_LANGEVIN_OU          = 8, &
			THERMOSTAT_LANGEVIN_NPT_NB      = 9, &
			THERMOSTAT_ALL_PURPOSE          = 10

  !% Nose-Hoover thermostat ---
  !% Hoover, W.G., \emph{Phys. Rev.}, {\bfseries A31}, 1695 (1985)
  
  !% Langevin thermostat - fluctuation/dissipation ---
  !% Quigley, D. and Probert, M.I.J., \emph{J. Chem. Phys.}, 
  !% {\bfseries 120} 11432

  !% Nose-Hoover-Langevin thermostat --- me!

  !% all-purpose adaptive Langevin
  !% Jones and Leimkuhler, \emph{J. Chem. Phys.} {\bfseries 135}, 084125 (2011).

  !% all-purpose Nose-Hoover-Langevin
  !% Leimkuhler private communication (?)

  type thermostat

     integer  :: type  = THERMOSTAT_NONE     !% One of the types listed above
     real(dp) :: gamma = 0.0_dp   !% Friction coefficient in Langevin and Nose-Hoover-Langevin
     real(dp) :: NHL_gamma = 0.0_dp   !% Friction coefficient in all-purpose thermostat NHL
     real(dp) :: eta   = 0.0_dp   !% $\eta$ variable in Nose-Hoover
     real(dp), allocatable :: chi_a(:)  !% $\chi$ variable in Leimkuhler's notation for Nose-Hoover
     real(dp), allocatable :: xi_a(:)  !% $\xi$ variable in Leimkuhler's notation for Nose-Hoover-Langevin
     real(dp) :: p_eta = 0.0_dp   !% $p_\eta$ variable in Nose-Hoover and Nose-Hoover-Langevin 
     real(dp) :: f_eta = 0.0_dp   !% The force on the Nose-Hoover(-Langevin) conjugate momentum
     real(dp) :: Q     = 0.0_dp   !% Thermostat mass in Nose-Hoover and Nose-Hoover-Langevin
     real(dp) :: NHL_mu    = 0.0_dp   !% Thermostat mass in all-purpose NHL
     real(dp) :: T     = 0.0_dp   !% Target temperature
     real(dp) :: Ndof  = 0.0_dp   !% The number of degrees of freedom of atoms attached to this thermostat
     real(dp) :: work  = 0.0_dp   !% Work done by this thermostat
     real(dp) :: p = 0.0_dp       !% External pressure
     real(dp) :: gamma_p = 0.0_dp !% Friction coefficient for cell in Langevin NPT
     real(dp) :: W_p = 0.0_dp     !% Fictious cell mass in Langevin NPT
     real(dp) :: epsilon_r = 0.0_dp !% Position of barostat variable
     real(dp) :: epsilon_v = 0.0_dp !% Velocity of barostat variable
     real(dp) :: epsilon_f = 0.0_dp !% Force on barostat variable
     real(dp) :: epsilon_f1 = 0.0_dp !% Force on barostat variable
     real(dp) :: epsilon_f2 = 0.0_dp !% Force on barostat variable
     real(dp) :: volume_0 = 0.0_dp !% Reference volume
     real(dp), dimension(3,3) :: lattice_v = 0.0_dp
     real(dp), dimension(3,3) :: lattice_f, lattice_f2 = 0.0_dp
     logical :: massive = .false.

  end type thermostat

  interface initialise
     module procedure thermostat_initialise
  end interface initialise

  interface finalise
     module procedure thermostat_finalise, thermostats_finalise
  end interface finalise

  interface assignment(=)
     module procedure thermostat_assignment, thermostat_array_assignment
  end interface assignment(=)

  interface print
     module procedure thermostat_print, thermostats_print
  end interface

  interface add_thermostat
     module procedure thermostats_add_thermostat
  end interface add_thermostat

  interface remove_thermostat
     module procedure thermostats_remove_thermostat
  end interface remove_thermostat

  interface add_thermostats
     module procedure thermostats_add_thermostats
  end interface add_thermostats

  interface update_thermostat
     module procedure thermostats_update_thermostat
  end interface update_thermostat

  interface set_degrees_of_freedom
     module procedure set_degrees_of_freedom_int, set_degrees_of_freedom_real
  end interface set_degrees_of_freedom

  interface nose_hoover_mass
     module procedure nose_hoover_mass_int, nose_hoover_mass_real
  end interface nose_hoover_mass

contains

  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  !X
  !X INITIALISE / FINALISE
  !X
  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

  subroutine thermostat_initialise(this,type,T,gamma,Q,p,gamma_p,W_p,volume_0,NHL_gamma,NHL_mu,massive)

    type(thermostat),   intent(inout) :: this
    integer,            intent(in)    :: type
    real(dp), optional, intent(in)    :: T
    real(dp), optional, intent(in)    :: gamma
    real(dp), optional, intent(in)    :: Q
    real(dp), optional, intent(in)    :: p
    real(dp), optional, intent(in)    :: gamma_p
    real(dp), optional, intent(in)    :: W_p
    real(dp), optional, intent(in)    :: volume_0
    real(dp), optional, intent(in)    :: NHL_gamma,NHL_mu
    logical, optional, intent(in)     :: massive

    real(dp) :: use_Q

    if (present(T)) then
       if (T < 0.0_dp) call system_abort('initialise: Temperature must be >= 0')
    end if

    if (type /= THERMOSTAT_NONE .and. .not.present(T)) &
         call system_abort('initialise: T must be specified when turning on a thermostat')

    this%type = type
    this%work = 0.0_dp
    this%eta = 0.0_dp
    if (allocated(this%chi_a)) deallocate(this%chi_a)
    if (allocated(this%xi_a)) deallocate(this%xi_a)
    this%p_eta = 0.0_dp
    this%f_eta = 0.0_dp
    this%epsilon_r = 0.0_dp
    this%epsilon_v = 0.0_dp
    this%epsilon_f = 0.0_dp
    this%epsilon_f1 = 0.0_dp
    this%epsilon_f2 = 0.0_dp
    this%volume_0 = 0.0_dp
    this%p = 0.0_dp
    this%lattice_v = 0.0_dp
    this%lattice_f = 0.0_dp
    this%lattice_f2 = 0.0_dp

    use_Q = optional_default(-1.0_dp, Q)

    select case(this%type)

    case(THERMOSTAT_NONE) 

       this%T = 0.0_dp
       this%gamma = 0.0_dp
       this%Q = 0.0_dp

    case(THERMOSTAT_LANGEVIN)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_LANGEVIN does not implement massive flag")
       endif

       if (.not.present(gamma)) call system_abort('thermostat initialise: gamma is required for Langevin thermostat')
       if (gamma < 0.0_dp) call system_abort('thermostat initialise: gamma must be >= 0 for Langevin')
       this%T = T
       this%gamma = gamma
       this%Q = use_Q

    case(THERMOSTAT_NOSE_HOOVER)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_NOSE_HOOVER does not implement massive flag")
       endif

       if (.not.present(Q)) call system_abort('thermostat initialise: Q is required for Nose-Hoover thermostat')
       if (Q <= 0.0_dp) call system_abort('thermostat initialise: Q must be > 0')
       this%T = T      
       this%gamma = 0.0_dp
       this%Q = Q

    case(THERMOSTAT_NOSE_HOOVER_LANGEVIN)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_NOSE_HOOVER_LANGEVIN does not implement massive flag")
       endif

       if (.not.present(gamma)) &
            call system_abort('thermostat initialise: gamma is required for Nose-Hoover-Langevin thermostat')
       if (gamma < 0.0_dp) call system_abort('thermostat initialise: gamma must be >= 0')
       if (.not.present(Q)) call system_abort('thermostat initialise: Q is required for Nose-Hoover-Langevin thermostat')
       if (Q <= 0.0_dp) call system_abort('thermostat initialise: Q must be > 0')
       this%T = T       
       this%gamma = gamma
       this%Q = Q

    case(THERMOSTAT_LANGEVIN_NPT)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_LANGEVIN_NPT does not implement massive flag")
       endif

       if (.not.present(gamma) .or. .not.present(p) .or. .not.present(gamma_p) .or. .not.present(W_p) .or. .not.present(volume_0) ) &
       & call system_abort('thermostat initialise: p, gamma, gamma_p, W_p and volume_0 are required for Langevin NPT baro-thermostat')
       this%T = T
       this%gamma = gamma
       this%Q = 0.0_dp
       this%p = p
       this%gamma_p = gamma_p
       this%W_p = W_p
       this%volume_0 = volume_0
       this%Q = use_Q

    case(THERMOSTAT_LANGEVIN_PR)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_LANGEVIN_PR does not implement massive flag")
       endif

       if (.not.present(gamma) .or. .not.present(p) .or. .not.present(W_p) .or. .not.present(gamma_p) ) &
       & call system_abort('initialise: p, gamma, W_p are required for Langevin Parrinello-Rahman baro-thermostat')
       this%T = T
       this%gamma = gamma
       this%Q = 0.0_dp
       this%p = p
       this%gamma_p = gamma_p
       this%W_p = W_p
       this%Q = use_Q

    case(THERMOSTAT_NPH_ANDERSEN)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_NPH_ANDERSEN does not implement massive flag")
       endif

       if (.not.present(W_p) .or. .not.present(p) .or. .not.present(volume_0) .or. .not.present(gamma_p) ) &
       & call system_abort('thermostat initialise: p, W_p and volume_0 are required for Andersen THERMOSTAT_NPH barostat')
       this%T = 0.0_dp
       this%gamma = 0.0_dp
       this%Q = 0.0_dp
       this%p = p
       this%gamma_p = gamma_p
       this%W_p = W_p
       this%volume_0 = volume_0

    case(THERMOSTAT_NPH_PR)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_NPH_PR does not implement massive flag")
       endif

       if (.not.present(p) .or. .not.present(W_p) .or. .not.present(gamma_p) ) &
       & call system_abort('initialise: p and W_p are required for THERMOSTAT_NPH Parrinello-Rahman barostat')
       this%T = 0.0_dp
       this%gamma = 0.0_dp
       this%Q = 0.0_dp
       this%p = p
       this%gamma_p = gamma_p
       this%W_p = W_p

    case(THERMOSTAT_LANGEVIN_OU)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_LANGEVIN_OU does not implement massive flag")
       endif

       if (.not.present(gamma)) call system_abort('thermostat initialise: gamma is required for Langevin OU thermostat')
       if (gamma < 0.0_dp) call system_abort('thermostat initialise: gamma must be >= 0 for Langevin OU')
       this%T = T
       this%gamma = gamma
       this%Q = use_Q

    case(THERMOSTAT_LANGEVIN_NPT_NB)
       if (present(massive)) then
	 if (massive) call system_abort("THERMOSTAT_LANGEVIN_NPT_NB does not implement massive flag")
       endif

       if (.not.present(gamma) .or. .not.present(p) .or. .not.present(gamma_p) .or. .not. present(W_p) ) &
       & call system_abort('thermostat initialise: p, gamma, gamma_p, W_p and volume_0 are required for Langevin NPT baro-thermostat')
       this%T = T
       this%gamma = gamma
       this%Q = use_Q
       this%p = p
       this%gamma_p = gamma_p
       this%W_p = W_p

    case(THERMOSTAT_ALL_PURPOSE)
       this%T = T
       this%gamma = optional_default(0.0_dp, gamma)
       this%NHL_gamma = optional_default(0.0_dp, NHL_gamma)
       this%Q = optional_default(-1.0_dp, Q)
       this%NHL_mu = optional_default(-1.0_dp, NHL_mu)
       this%massive = optional_default(.false., massive)


       if (count( (/ this%NHL_gamma > 0.0_dp, this%NHL_mu > 0.0_dp /) ) == 1) call system_abort("THERMOSTAT_ALL_PURPOSE needs NHL_gamma="//this%NHL_gamma//" and NHL_mu="//this%NHL_mu//" either both or neither > 0")

    end select

  end subroutine thermostat_initialise

  subroutine thermostat_finalise(this)

    type(thermostat), intent(inout) :: this

    this%type  = THERMOSTAT_NONE  
    this%gamma = 0.0_dp
    this%NHL_gamma = 0.0_dp
    this%eta   = 0.0_dp
    this%p_eta = 0.0_dp 
    this%f_eta = 0.0_dp
    this%Q     = 0.0_dp
    this%NHL_mu = 0.0_dp
    this%T     = 0.0_dp
    this%Ndof  = 0.0_dp
    this%work  = 0.0_dp
    this%p     = 0.0_dp
    this%gamma_p = 0.0_dp
    this%W_p = 0.0_dp
    this%epsilon_r = 0.0_dp
    this%epsilon_v = 0.0_dp
    this%epsilon_f = 0.0_dp
    this%epsilon_f1 = 0.0_dp
    this%epsilon_f2 = 0.0_dp
    this%lattice_v = 0.0_dp
    this%lattice_f = 0.0_dp
    this%lattice_f2 = 0.0_dp
    this%massive = .false.
    
  end subroutine thermostat_finalise

  subroutine thermostat_assignment(to,from)

    type(thermostat), intent(out) :: to
    type(thermostat), intent(in)  :: from

    to%type  = from%type      
    to%gamma = from%gamma 
    to%NHL_gamma = from%NHL_gamma 
    to%eta   = from%eta   
    if (allocated(from%chi_a)) then
       if (allocated(to%chi_a)) deallocate(to%chi_a)
       allocate(to%chi_a(size(from%chi_a)))
       to%chi_a = from%chi_a
    else
      if (allocated(to%chi_a)) deallocate(to%chi_a)
    endif
    if (allocated(from%xi_a)) then
       if (allocated(to%xi_a)) deallocate(to%xi_a)
       allocate(to%xi_a(size(from%xi_a)))
       to%xi_a = from%xi_a
    else
      if (allocated(to%xi_a)) deallocate(to%xi_a)
    endif
    to%p_eta = from%p_eta 
    to%Q     = from%Q     
    to%NHL_mu     = from%NHL_mu
    to%T     = from%T     
    to%Ndof  = from%Ndof
    to%work  = from%work  
    to%p     = from%p
    to%gamma_p = from%gamma_p
    to%W_p = from%W_p
    to%epsilon_r = from%epsilon_r
    to%epsilon_v = from%epsilon_v
    to%epsilon_f = from%epsilon_f
    to%epsilon_f1 = from%epsilon_f1
    to%epsilon_f2 = from%epsilon_f2
    to%volume_0 = from%volume_0
    to%lattice_v = from%lattice_v
    to%lattice_f = from%lattice_f
    to%lattice_f2 = from%lattice_f2
    to%massive = from%massive

  end subroutine thermostat_assignment

  !% Copy an array of thermostats
  subroutine thermostat_array_assignment(to, from)
    type(thermostat), allocatable, intent(inout) :: to(:)
    type(thermostat), allocatable, intent(in) :: from(:)
    
    integer :: u(1), l(1), i

    if (allocated(to)) deallocate(to)
    u = ubound(from)
    l = lbound(from)
    allocate(to(l(1):u(1)))
    do i=l(1),u(1)
       to(i) = from(i)
    end do

  end subroutine thermostat_array_assignment

  !% Finalise an array of thermostats
  subroutine thermostats_finalise(this)

    type(thermostat), allocatable, intent(inout) :: this(:)

    integer :: i, ua(1), la(1), u, l
    
    if (allocated(this)) then
       ua = ubound(this); u = ua(1)
       la = lbound(this); l = la(1)
       do i = l, u
          call finalise(this(i))
       end do
       deallocate(this)
    end if

  end subroutine thermostats_finalise

  subroutine thermostats_remove_thermostat(this,index)
    type(thermostat), allocatable, intent(inout) :: this(:)
    integer, intent(in) :: index

    type(thermostat), allocatable                :: temp(:)
    integer                                      :: i, l, u, la(1), ua(1)

    if (.not. allocated(this)) &
         call system_abort('thermostats array not allocataed')

    la = lbound(this); l=la(1)
    ua = ubound(this); u=ua(1)
    
    if (index < l .or. index > u) &
         call system_abort('index '//index//' outside of range '//l//' <= index <= '//u)
         
    allocate(temp(l:u))
    do i = l,u
       temp(i) = this(i)
    end do
    call finalise(this)
    
    allocate(this(l:u-1))
    do i = l,u
       if (i == index) cycle
       this(i) = temp(i)
    end do
    call finalise(temp)

  end subroutine thermostats_remove_thermostat

  subroutine thermostats_add_thermostat(this,type,T,gamma,Q,p,gamma_p,W_p,volume_0,NHL_gamma,NHL_mu,massive,region_i)

    type(thermostat), allocatable, intent(inout) :: this(:)
    integer,                       intent(in)    :: type
    real(dp), optional,            intent(in)    :: T
    real(dp), optional,            intent(in)    :: gamma
    real(dp), optional,            intent(in)    :: Q
    real(dp), optional,            intent(in)    :: p
    real(dp), optional,            intent(in)    :: gamma_p
    real(dp), optional,            intent(in)    :: W_p
    real(dp), optional,            intent(in)    :: volume_0
    real(dp), optional,            intent(in)    :: NHL_gamma, NHL_mu
    logical, optional,             intent(in)    :: massive
    integer, optional,             intent(out)    :: region_i

    type(thermostat), allocatable                :: temp(:)
    integer                                      :: i, l, u, la(1), ua(1)

    if (allocated(this)) then
       la = lbound(this); l=la(1)
       ua = ubound(this); u=ua(1)
       allocate(temp(l:u))
       do i = l,u
          temp(i) = this(i)
       end do
       call finalise(this)
    else
       l=1
       u=0
    end if
    
    allocate(this(l:u+1))

    if (allocated(temp)) then
       do i = l,u
          this(i) = temp(i)
       end do
       call finalise(temp)
    end if

    call initialise(this(u+1),type,T=T,gamma=gamma,Q=Q,p=p,gamma_p=gamma_p,W_p=W_p,volume_0=volume_0,NHL_gamma=NHL_gamma,NHL_mu=NHL_mu,massive=massive)

    if (present(region_i)) region_i=u+1

  end subroutine thermostats_add_thermostat

  subroutine thermostats_add_thermostats(this,type,n,T_a,gamma_a,Q_a,region_i)

    type(thermostat), allocatable, intent(inout) :: this(:)
    integer,                       intent(in)    :: type
    integer,                       intent(in)    :: n
    real(dp), optional,            intent(in)    :: T_a(:)
    real(dp), optional,            intent(in)    :: gamma_a(:)
    real(dp), optional,            intent(in)    :: Q_a(:)
    integer, optional,             intent(out)    :: region_i

    type(thermostat), allocatable                :: temp(:)
    integer                                      :: i, l, u, la(1), ua(1)

    if (allocated(this)) then
       la = lbound(this); l=la(1)
       ua = ubound(this); u=ua(1)
       allocate(temp(l:u))
       do i = l,u
          temp(i) = this(i)
       end do
       call finalise(this)
    else
       l=1
       u=0
    end if
    
    allocate(this(l:u+n))

    if (allocated(temp)) then
       do i = l,u
          this(i) = temp(i)
       end do
       call finalise(temp)
    end if

    do i=1, n
      if (present(T_a)) then
	 if (present(Q_a)) then
	    if (present(gamma_a)) then
	       call initialise(this(u+i),type,T=T_a(i),gamma=gamma_a(i),Q=Q_a(i))
	    else
	       call initialise(this(u+i),type,T=T_a(i),Q=Q_a(i))
	    endif
	 else ! no Q_a
	    if (present(gamma_a)) then
	       call initialise(this(u+i),type,T=T_a(i),gamma=gamma_a(i))
	    else
	       call initialise(this(u+i),type,T=T_a(i))
	    endif
	 endif
      else ! no T_A
	 if (present(Q_a)) then
	    if (present(gamma_a)) then
	       call initialise(this(u+i),type,gamma=gamma_a(i),Q=Q_a(i))
	    else
	       call initialise(this(u+i),type,Q=Q_a(i))
	    endif
	 else ! no Q_aa
	    if (present(gamma_a)) then
	       call initialise(this(u+i),type,gamma=gamma_a(i))
	    else
	       call initialise(this(u+i),type)
	    endif
	 endif
      endif
    end do

    if (present(region_i)) region_i=u+1

  end subroutine thermostats_add_thermostats

  subroutine thermostats_update_thermostat(this,T,p,w_p)

    type(thermostat),   intent(inout) :: this
    real(dp), optional, intent(in)    :: T
    real(dp), optional, intent(in)    :: p
    real(dp), optional, intent(in)    :: w_p

    if( present(T) ) this%T = T
    if( present(p) ) this%p = p
    if( present(w_p) ) this%w_p = w_p

  endsubroutine thermostats_update_thermostat

  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  !X
  !X PRINTING
  !X
  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

  subroutine thermostat_print(this,file)

    type(thermostat),         intent(in) :: this
    type(inoutput), optional, intent(in) :: file
    select case(this%type)

    case(THERMOSTAT_NONE)
       call print('Thermostat off',file=file)

    case(THERMOSTAT_LANGEVIN)
       call print('Langevin, T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, eta = '//&
	    round(this%eta,5)//' (#), work = '//round(this%work,5)//' eV, Ndof = '// round(this%Ndof,1),file=file)

    case(THERMOSTAT_NOSE_HOOVER)
       call print('Nose-Hoover, T = '//round(this%T,2)//' K, Q = '//round(this%Q,5)//' eV fs^2, eta = '//&
            round(this%eta,5)//' (#), p_eta = '//round(this%p_eta,5)//' eV fs, work = '//round(this%work,5)//' eV, Ndof = ' // round(this%Ndof,1),file=file)

    case(THERMOSTAT_NOSE_HOOVER_LANGEVIN)
       call print('Nose-Hoover-Langevin, T = '//round(this%T,2)//' K, Q = '//round(this%Q,5)//&
            ' eV fs^2, gamma = '//round(this%gamma,5)//' fs^-1, eta = '//round(this%eta,5)//&
            ' , p_eta = '//round(this%p_eta,5)//' eV fs, work = '//round(this%work,5)//' eV, Ndof = ' // round(this%Ndof,1),file=file)
       
    case(THERMOSTAT_LANGEVIN_NPT)
       call print('Langevin NPT, T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, eta = '//&
	    round(this%eta,5)//' (#), work = '// round(this%work,5)//' eV, p = '//round(this%p,5)//' eV/A^3, gamma_p = '// &
            round(this%gamma_p,5)//' fs^-1, W_p = '//round(this%W_p,5)//' au, Ndof = ' // round(this%Ndof,1),file=file)

    case(THERMOSTAT_LANGEVIN_PR)
       call print('Langevin PR, T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, eta = '//&
	    round(this%eta,5)//' (#), work = '// round(this%work,5)//' eV, p = '//round(this%p,5)//' eV/A^3, gamma_p = '// &
            round(this%gamma_p,5)//' fs^-1, W_p = '//round(this%W_p,5)//' au',file=file)

    case(THERMOSTAT_NPH_ANDERSEN)
       call print('Andersen THERMOSTAT_NPH, work = '// round(this%work,5)//' eV, p = '//round(this%p,5)//' eV/A^3, W_p = '//round(this%W_p,5)//' au, Ndof = ' // round(this%Ndof,1),file=file)

    case(THERMOSTAT_NPH_PR)
       call print('Parrinello-Rahman THERMOSTAT_NPH, work = '// round(this%work,5)//' eV, p = '//round(this%p,5)//' eV/A^3, W_p = '//round(this%W_p,5)//' au, Ndof = ' // round(this%Ndof,1),file=file)

    case(THERMOSTAT_LANGEVIN_OU)
       call print('Langevin OU, T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, eta = '//&
	    round(this%eta,5)//' (#), work = '//round(this%work,5)//' eV, Ndof = '// round(this%Ndof,1),file=file)

    case(THERMOSTAT_LANGEVIN_NPT_NB)
       call print('Langevin NPT, T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, eta = '//&
	    round(this%eta,5)//' (#), work = '// round(this%work,5)//' eV, p = '//round(this%p,5)//' eV/A^3, gamma_p = '// &
            round(this%gamma_p,5)//' fs^-1, W_p = '//round(this%W_p,5)//' au, Ndof = ' // round(this%Ndof,1),file=file)

    case(THERMOSTAT_ALL_PURPOSE)
       if (this%massive) then
	  call print('All-purpose adaptive-Langevin , T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, chi = '//&
	       'too many to list (#), xi = too many to list (#), Ndof = ' // round(this%Ndof,1),file=file)
       else
	  if (.not. allocated(this%chi_a)) then
	     call print('All-purpose adaptive-Langevin , T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, NHL_mu = '//round(this%NHL_mu,5)//' eV fs^2, '//&
		'NHL_gamma = '//round(this%NHL_gamma,5)//' fs^-1, chi = '//round(0.0_dp,5)//' (#), xi = '//round(0.0_dp,5)//' Ndof = ' // round(this%Ndof,1),file=file)
	  else
	     call print('All-purpose adaptive-Langevin , T = '//round(this%T,2)//' K, gamma = '//round(this%gamma,5)//' fs^-1, Q = '//round(this%Q,5)//' eV fs^2, NHL_mu = '//round(this%NHL_mu,5)//' eV fs^2, '//&
		'NHL_gamma = '//round(this%NHL_gamma,5)//' fs^-1, chi = '//round(this%chi_a(1),5)//' (#), xi = '//round(this%xi_a(1),5)//' Ndof = ' // round(this%Ndof,1),file=file)
	  endif
       endif

    end select
    
  end subroutine thermostat_print

  subroutine thermostats_print(this,file)
    
    type(thermostat), allocatable, intent(in) :: this(:)
    type(inoutput), optional,      intent(in) :: file

    integer :: u, l, i, ua(1), la(1)

    la=lbound(this); l=la(1)
    ua=ubound(this); u=ua(1)

    do i = l,u
       call print('Thermostat '//i//':',file=file)
       call print(this(i),file)
    end do

  end subroutine thermostats_print

  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  !X
  !X SETTING Ndof
  !X
  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

  subroutine set_degrees_of_freedom_int(this,Ndof)

    type(thermostat), intent(inout) :: this
    integer,          intent(in)    :: Ndof

    this%Ndof = real(Ndof,dp)

  end subroutine set_degrees_of_freedom_int

  subroutine set_degrees_of_freedom_real(this,Ndof)

    type(thermostat), intent(inout) :: this
    real(dp),         intent(in)    :: Ndof

    this%Ndof = Ndof

  end subroutine set_degrees_of_freedom_real

  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  !X
  !X CHOOSING NOSE-HOOVER(-THERMOSTAT_LANGEVIN) MASS
  !X
  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

  pure function nose_hoover_mass_int(Ndof,T,tau) result(Q)

    integer,  intent(in) :: Ndof
    real(dp), intent(in) :: T, tau
    real(dp)             :: Q

    Q = nose_hoover_mass_real(real(Ndof,dp),T,tau)

  end function nose_hoover_mass_int
    
  pure function nose_hoover_mass_real(Ndof,T,tau) result(Q)

    real(dp), intent(in) :: Ndof, T, tau
    real(dp)             :: Q

    if (tau < 0.0) then
       Q = -1.0_dp
    else
       Q = Ndof*BOLTZMANN_K*T*tau*tau/(4.0_dp*PI*PI)
    endif

  end function nose_hoover_mass_real

  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  !X
  !X THERMOSTAT ROUTINES
  !X
  !X These routines interleave the usual velocity Verlet steps and should modify 
  !X the velocities and accelerations as required:
  !X
  !X advance_verlet1
  !X   00 (barostat_pre_vel1) *
  !X   10 (thermostat_pre_vel1) *
  !X   20 v(t+dt/2) = v(t) + a(t)dt/2
  !X   30 (thermostat_post_vel1_pre_pos)
  !X   40 r(t+dt) = r(t) + v(t+dt/2)dt
  !X   50 (thermostat_post_pos_pre_calc)
  !X   60 (barostat_post_pos_pre_calc) *
  !X calc F, virial
  !X advance_verlet2
  !X   70 (thermostat_post_calc_pre_vel2) *
  !X   80 v(t+dt) = v(t+dt/2) + a(t+dt)dt/2
  !X   90 (thermostat_post_vel2) *
  !X   100 (barostat_post_vel2) *
  !X
  !X * marks routines that are needed in the refactored barostat/thermostat plan
  !X
  !X A thermostat can be applied to part of the atomic system by passing an integer
  !X atomic property and the value it must have.
  !X
  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  
  subroutine thermostat_pre_vel1(this,at,dt,property,value,virial)

    type(thermostat), intent(inout) :: this
    type(atoms),      intent(inout) :: at
    real(dp),         intent(in)    :: dt
    character(*),     intent(in)    :: property
    integer,          intent(in)    :: value
    real(dp), dimension(3,3), intent(in), optional :: virial

    real(dp) :: decay, K, volume_p, rv_mag, OU_dv(3)
    real(dp), dimension(3,3) :: lattice_p, ke_virial, decay_matrix, decay_matrix_eigenvectors, exp_decay_matrix
    real(dp), dimension(3) :: decay_matrix_eigenvalues
    integer  :: i
    integer, dimension(:), pointer :: prop_ptr
    real(dp) :: delta_K

    if (.not. assign_pointer(at,property,prop_ptr)) then
       call system_abort('thermostat_pre_vel1: cannot find property '//property)
    end if
 
    select case(this%type)

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN)
              
       !Decay the velocity for dt/2. The random force will have been added to acc during the
       !previous timestep.

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       decay = exp(-0.5_dp*(this%gamma+this%eta)*dt)
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_NOSE_HOOVER)
       
       !Propagate eta for dt (this saves doing it twice, for dt/2)
       if (this%Q > 0.0_dp) then
	 this%eta = this%eta + this%p_eta*dt/this%Q
       else
	 this%eta = 0.0_dp
       endif

       !Decay the velocities using p_eta for dt/2. Also, accumulate the (pre-decay)
       !kinetic energy (x2) and use to integrate the 'work' value
       K = 0.0_dp
       if (this%Q > 0.0_dp) then
	 decay = exp(-0.5_dp*this%p_eta*dt/this%Q)
       else
	 decay = 1.0_dp
       endif

!       dvelo = 0.0_dp
!       ntherm = 0
       do i=1, at%N
          if (prop_ptr(i) /= value) cycle
          K = K + at%mass(i)*normsq(at%velo(:,i))
!	  dvelo = dvelo + norm(at%velo(:,i))*abs(1.0_dp-decay)
!	  ntherm = ntherm + 1
          at%velo(:,i) = at%velo(:,i)*decay
       end do
!       call print("Thermostat " // value //" thermostat_pre_vel1 N-H <delta vel>"//(dvelo/real(ntherm,dp)))

       !Propagate the work for dt/2
       if (this%Q > 0.0_dp) then
	 this%work = this%work + 0.5_dp*this%p_eta*K*dt/this%Q
       endif

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER-THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_NOSE_HOOVER_LANGEVIN)
       
       !Decay p_eta for dt/2 and propagate it for dt/2
       this%p_eta = this%p_eta*exp(-0.5_dp*this%gamma*dt) + 0.5_dp*this%f_eta*dt
       !Propagate eta for dt (this saves doing it twice, for dt/2)
       if (this%Q > 0.0_dp) then
	 this%eta = this%eta + this%p_eta*dt/this%Q
       else
	 this%eta = 0.0_dp
       endif

       !Decay the velocities using p_eta for dt/2 and accumulate Ek (as in NH) for
       !work integration
       if (this%Q > 0.0_dp) then
	 decay = exp(-0.5_dp*this%p_eta*dt/this%Q)
       else
	 decay = 1.0_dp
       endif
       K = 0.0_dp

       do i = 1, at%N
          if(prop_ptr(i) /= value) cycle
          K = K + at%mass(i)*normsq(at%velo(:,i))
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       !Propagate work
       if (this%Q > 0.0_dp) then
	 this%work = this%work + 0.5_dp*this%p_eta*K*dt/this%Q
       endif

       ! advance_verlet1 will do conservative + random force parts of v half step

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN NPT, Andersen barostat
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN_NPT)
              
       if( .not. present(virial) ) call system_abort('thermostat_pre_vel1: NPT &
       & simulation, but virial has not been passed')

       this%epsilon_r = this%epsilon_r + 0.5_dp*this%epsilon_v*dt
       volume_p = exp(3.0_dp*this%epsilon_r)*this%volume_0
       lattice_p = at%lattice * (volume_p/cell_volume(at))**(1.0_dp/3.0_dp)
       call set_lattice(at,lattice_p, scale_positions=.false.)

       this%epsilon_f1 = (1.0_dp + 3.0_dp/this%Ndof)*sum(at%mass*sum(at%velo**2,dim=1)) + trace(virial) &
       & - 3.0_dp * volume_p * this%p

       this%epsilon_f = this%epsilon_f1 + this%epsilon_f2
       this%epsilon_v = this%epsilon_v + 0.5_dp * dt * this%epsilon_f / this%W_p

       !Decay the velocity for dt/2. The random force will have been added to acc during the
       !previous timestep.

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       decay = exp(-0.5_dp*dt*((this%gamma+this%eta)+(1.0_dp + 3.0_dp/this%Ndof)*this%epsilon_v))
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
          at%pos(:,i) = at%pos(:,i)*( 1.0_dp + this%epsilon_v * dt )
       end do
       !at%pos = at%pos*exp(this%epsilon_vp * dt) ????

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN NPT, Parrinello-Rahman barostat
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN_PR)
              
       if( .not. present(virial) ) call system_abort('thermostat_pre_vel1: NPT &
       & simulation, but virial has not been passed')

       lattice_p = at%lattice + 0.5_dp * dt * matmul(this%lattice_v,at%lattice)

       call set_lattice(at,lattice_p, scale_positions=.false.)
       volume_p = cell_volume(at)

       ke_virial = matmul(at%velo*spread(at%mass,dim=1,ncopies=3),transpose(at%velo))

       this%lattice_f = ke_virial + virial - this%p*volume_p*matrix_one + trace(ke_virial)*matrix_one/this%Ndof + this%lattice_f2
       this%lattice_v = this%lattice_v + 0.5_dp*dt*this%lattice_f / this%W_p

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif
       
       !Decay the velocity for dt/2. The random force will have been added to acc during the
       !previous timestep.

       decay_matrix = -0.5_dp*dt*( (this%gamma+this%eta)*matrix_one + this%lattice_v + trace(this%lattice_v)*matrix_one/this%Ndof )
       decay_matrix = ( decay_matrix + transpose(decay_matrix) ) / 2.0_dp ! Making sure the matrix is exactly symmetric
       call diagonalise(decay_matrix,decay_matrix_eigenvalues,decay_matrix_eigenvectors)
       exp_decay_matrix = matmul( decay_matrix_eigenvectors, matmul( diag(exp(decay_matrix_eigenvalues)), transpose(decay_matrix_eigenvectors) ) )
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = matmul(exp_decay_matrix,at%velo(:,i))
          !at%velo(:,i) = at%velo(:,i) + matmul(decay_matrix,at%velo(:,i))
          at%pos(:,i) = at%pos(:,i) + matmul(this%lattice_v,at%pos(:,i))*dt
       end do
       !at%pos = at%pos*exp(this%epsilon_vp * dt) ????

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_NPH, Andersen barostat
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_NPH_ANDERSEN)
              
       if( .not. present(virial) ) call system_abort('thermostat_pre_vel1: THERMOSTAT_NPH &
       & simulation, but virial has not been passed')

       this%epsilon_r = this%epsilon_r + 0.5_dp*this%epsilon_v*dt
       volume_p = exp(3.0_dp*this%epsilon_r)*this%volume_0
       lattice_p = at%lattice * (volume_p/cell_volume(at))**(1.0_dp/3.0_dp)
       call set_lattice(at,lattice_p, scale_positions=.false.)

       this%epsilon_f = (1.0_dp + 3.0_dp/this%Ndof)*sum(at%mass*sum(at%velo**2,dim=1)) + trace(virial) &
       & - 3.0_dp * volume_p * this%p

       this%epsilon_v = this%epsilon_v + 0.5_dp * dt * this%epsilon_f / this%W_p

       !Decay the velocity for dt/2. The random force will have been added to acc during the
       !previous timestep.

       decay = exp(-0.5_dp*dt*(1.0_dp + 3.0_dp/this%Ndof)*this%epsilon_v)
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
          at%pos(:,i) = at%pos(:,i)*( 1.0_dp + this%epsilon_v * dt )
       end do

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_NPH, Parrinello-Rahman barostat
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_NPH_PR)
              
       if( .not. present(virial) ) call system_abort('thermostat_pre_vel1: THERMOSTAT_NPH &
       & simulation, but virial has not been passed')

       lattice_p = at%lattice + 0.5_dp * dt * matmul(this%lattice_v,at%lattice)

       call set_lattice(at,lattice_p, scale_positions=.false.)
       volume_p = cell_volume(at)

       ke_virial = matmul(at%velo*spread(at%mass,dim=1,ncopies=3),transpose(at%velo))

       this%lattice_f = ke_virial + virial - this%p*volume_p*matrix_one + trace(ke_virial)*matrix_one/this%Ndof
       this%lattice_v = this%lattice_v + 0.5_dp*dt*this%lattice_f / this%W_p
       
       !Decay the velocity for dt/2. 

       decay_matrix = -0.5_dp*dt*( this%lattice_v + trace(this%lattice_v)*matrix_one/this%Ndof )
       decay_matrix = ( decay_matrix + transpose(decay_matrix) ) / 2.0_dp ! Making sure the matrix is exactly symmetric
       call diagonalise(decay_matrix,decay_matrix_eigenvalues,decay_matrix_eigenvectors)
       exp_decay_matrix = matmul( decay_matrix_eigenvectors, matmul( diag(exp(decay_matrix_eigenvalues)), transpose(decay_matrix_eigenvectors) ) )
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = matmul(exp_decay_matrix,at%velo(:,i))
          !at%velo(:,i) = at%velo(:,i) + matmul(decay_matrix,at%velo(:,i))
          at%pos(:,i) = at%pos(:,i) + matmul(this%lattice_v,at%pos(:,i))*dt
       end do

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN with Ornstein-Uhlenbeck dynamics (Leimkuhler e-mail)
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN_OU)
              
       !Decay the velocity for dt/2 by eta (aka chi)

       if (this%eta /= 0.0_dp) then
	  decay = exp(-0.5_dp*this%eta*dt)
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       endif

    case(THERMOSTAT_LANGEVIN_NPT_NB)
       if( .not. present(virial) ) call system_abort('thermostat_pre_vel1: NPT &
	  simulation, but virial has not been passed')

       ! half step epsilon_v, drag and force (from last step) parts 
       this%epsilon_v = this%epsilon_v*exp(-0.5_dp*dt*this%gamma_p)
       this%epsilon_v = this%epsilon_v + 0.5_dp*dt*this%epsilon_f/this%W_p

       ! half step barostat drag part of v
       decay = exp(-0.5_dp*dt*((1.0_dp + 3.0_dp/this%Ndof)*this%epsilon_v))
       at%velo = at%velo*decay

       ! Leimkuhler+Jones adaptive Langevin
       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       ! half step Langevin drag part of v
       decay = exp(-0.5_dp*dt*(this%gamma+this%eta))
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       ! Leimkuhler+Jones adaptive Langevin
       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif


       ! half step position affine defomration
       lattice_p = at%lattice
       call set_lattice(at, lattice_p*exp(0.5_dp*dt*this%epsilon_v), scale_positions=.false.)
       at%pos = at%pos*exp(0.5_dp*dt*this%epsilon_v)

    case(THERMOSTAT_ALL_PURPOSE)
       !TIME_PROPAG_TEX 10 before first Verlet velocity step (thermostat\_pre\_vel1) 
       !TIME_PROPAG_TEX 10
       !TIME_PROPAG_TEX 10 $\chi$ Nose Hoover extended DOF (also part of open Langevin)
       !TIME_PROPAG_TEX 10
       !TIME_PROPAG_TEX 10 $\gamma$ Langevin decay rate = 1/time constant (also part of open Langevin)
       !TIME_PROPAG_TEX 10
       !TIME_PROPAG_TEX 10 $\xi$ Nose Hoover Langevin extended DOF
       !TIME_PROPAG_TEX 10
       !TIME_PROPAG_TEX 10 $r.v.$ is normal random variable, variance 1
       !TIME_PROPAG_TEX 10
       !TIME_PROPAG_TEX 10 $$ v = v \exp(-(\tau/2) \gamma) + \sqrt{k_B T \frac{1-\exp(-\tau\gamma)}{m}}~r.v.$$
       !TIME_PROPAG_TEX 10 $$ \Delta K = 1/2 \left( \sum_i m_i \left| v_i \right|^2 - N_d k_B T \right) $$
       !TIME_PROPAG_TEX 10 $$ \chi = \chi + (\tau/2) \Delta K/Q $$
       !TIME_PROPAG_TEX 10 $$ \xi = \xi + (\tau/2) \Delta K/\mu $$
       !TIME_PROPAG_TEX 10 $$ v = v \exp(-0.25 \tau (\chi + \xi)) $$
       !TIME_PROPAG_TEX 10 $$ \xi = \xi \exp\left( -(\tau/2) \gamma_\mathrm{NHL} \right) + \sqrt{k_B T \frac{1-\exp(-\tau \gamma_\mathrm{NHL})}{\mu}}~r.v. $$
       !TIME_PROPAG_TEX 10 $$ v = v \exp(-0.25 \tau (\chi + \xi)) $$
       !TIME_PROPAG_TEX 10 $$ \Delta K = 1/2 \left( \sum_i m_i \left| v_i \right|^2 - N_d k_B T \right) $$
       !TIME_PROPAG_TEX 10 $$ \xi = \xi + (\tau/2) \Delta K/\mu $$
       !TIME_PROPAG_TEX 10 $$ \chi = \chi + (\tau/2) \Delta K/Q $$
       !TIME_PROPAG_TEX 10

       if (this%gamma > 0.0_dp .or. (this%NHL_gamma > 0.0_dp .and. this%NHL_mu > 0.0_dp)) call system_resync_rng()

       if (.not. allocated(this%chi_a)) then
	  if (this%massive) then
	    allocate(this%chi_a(count(prop_ptr == value)))
	    allocate(this%xi_a(count(prop_ptr == value)))
	  else
	    allocate(this%chi_a(1))
	    allocate(this%xi_a(1))
	  endif
	  this%chi_a = 0.0_dp
	  this%xi_a = 0.0_dp
       endif

       ! Random numbers may have been used at different rates on different MPI processes:
       ! we must resync the random number if we want the same numbers on each process.
       call system_resync_rng()
     
       if (this%gamma > 0.0_dp) then
	  ! Do the Ornstein-Uhlenbeck half step
	  decay=exp(-0.5_dp*this%gamma*dt)
	  rv_mag = sqrt(BOLTZMANN_K*this%T*(1.0_dp-decay**2))
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     OU_dv = rv_mag/sqrt(at%mass(i))*ran_normal3()
	     at%velo(:,i) = decay*at%velo(:,i) + OU_dv
	  end do
       end if 

       ! Leimkuhler+Jones adaptive Langevin
       ! propagate chi and xi dt/4
       if (this%Q > 0.0_dp .or. this%NHL_mu > 0.0_dp) then
	  if (this%massive) then
	     do i = 1, at%N
		if (prop_ptr(i) /= value) cycle
		delta_K = open_Langevin_delta_K(1, at%mass(i:i), at%velo(1:3,i:i), 3.0_dp, this%T, prop_ptr(i:i), value)
		if (this%Q > 0.0_dp) this%chi_a(i) = this%chi_a(i) + 0.5_dp*dt*delta_K/this%Q
		if (this%NHL_mu > 0.0_dp) this%xi_a(i) = this%xi_a(i) + 0.5_dp*dt*delta_K/this%NHL_mu
	     end do
	  else
	     delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	     if (this%Q > 0.0_dp) this%chi_a = this%chi_a + 0.5_dp*dt*delta_K/this%Q
	     if (this%NHL_mu > 0.0_dp) this%xi_a = this%xi_a + 0.5_dp*dt*delta_K/this%NHL_mu
	  endif
       else
	  this%chi_a = 0.0_dp
	  this%xi_a = 0.0_dp
       endif

       ! quarter step drag part of v
       if (this%massive) then
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     decay = exp(-0.25_dp*dt*(this%chi_a(i)+this%xi_a(i)))
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       else
	  decay = exp(-0.25_dp*dt*(this%chi_a(1)+this%xi_a(1)))
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       endif

       ! Langevin half step for xi (if doing NHL)
       if (this%NHL_mu > 0.0_dp .and. this%NHL_gamma > 0.0_dp) then
	  if (this%massive) then
	     do i = 1, at%N
		if (prop_ptr(i) /= value) cycle
		this%xi_a(i) = this%xi_a(i)*exp(-0.5_dp*dt*this%NHL_gamma) + sqrt(BOLTZMANN_K*this%T*(1.0_dp-exp(-dt*this%NHL_gamma))/this%NHL_mu)*ran_normal()
	     end do
	  else
	     this%xi_a = this%xi_a*exp(-0.5_dp*dt*this%NHL_gamma) + sqrt(BOLTZMANN_K*this%T*(1.0_dp-exp(-dt*this%NHL_gamma))/this%NHL_mu)*ran_normal()
	  endif
       endif

       ! quarter step drag part of v
       if (this%massive) then
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     decay = exp(-0.25_dp*dt*(this%chi_a(i)+this%xi_a(i)))
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       else
	  decay = exp(-0.25_dp*dt*(this%chi_a(1)+this%xi_a(1)))
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       endif

       ! Leimkuhler+Jones adaptive Langevin
       ! propagate chi and xi dt/4
       if (this%Q > 0.0_dp .or. this%NHL_mu > 0.0_dp) then
	  if (this%massive) then
	     do i = 1, at%N
		if (prop_ptr(i) /= value) cycle
		delta_K = open_Langevin_delta_K(1, at%mass(i:i), at%velo(1:3,i:i), 3.0_dp, this%T, prop_ptr(i:i), value)
		if (this%Q > 0.0_dp) this%chi_a(i) = this%chi_a(i) + 0.5_dp*dt*delta_K/this%Q
		if (this%NHL_mu > 0.0_dp) this%xi_a(i) = this%xi_a(i) + 0.5_dp*dt*delta_K/this%NHL_mu
	     end do
	  else
	     delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	     if (this%Q > 0.0_dp) this%chi_a = this%chi_a + 0.5_dp*dt*delta_K/this%Q
	     if (this%NHL_mu > 0.0_dp) this%xi_a = this%xi_a + 0.5_dp*dt*delta_K/this%NHL_mu
	  endif
       endif

    end select

  end subroutine thermostat_pre_vel1
  
  subroutine thermostat_post_vel1_pre_pos(this,at,dt,property,value)

    type(thermostat), intent(inout) :: this
    type(atoms),      intent(inout) :: at
    real(dp),         intent(in)    :: dt
    character(*),     intent(in)    :: property
    integer,          intent(in)    :: value

    integer, pointer, dimension(:) :: prop_ptr
    
    if (.not. assign_pointer(at,property,prop_ptr)) then
       call system_abort('thermostat_post_vel1_pre_pos: cannot find property '//property)
    end if
    
    select case(this%type)

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

    !case(THERMOSTAT_LANGEVIN)
       
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX


       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

    !case(THERMOSTAT_NOSE_HOOVER)

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX


       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER-THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       
    !case(THERMOSTAT_NOSE_HOOVER_LANGEVIN)


       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

    end select

  end subroutine thermostat_post_vel1_pre_pos

  subroutine thermostat_post_pos_pre_calc(this,at,dt,property,value)

    type(thermostat), intent(inout) :: this
    type(atoms),      intent(inout) :: at
    real(dp),         intent(in)    :: dt
    character(*),     intent(in)    :: property
    integer,          intent(in)    :: value

    real(dp) :: lattice_p(3,3)

    select case(this%type)

      case(THERMOSTAT_LANGEVIN_NPT_NB)

        ! half step position affine defomration
        lattice_p = at%lattice
        call set_lattice(at, lattice_p*exp(0.5_dp*dt*this%epsilon_v), scale_positions=.false.)
        at%pos = at%pos*exp(0.5_dp*dt*this%epsilon_v)

    end select

  end subroutine thermostat_post_pos_pre_calc

  subroutine thermostat_post_calc_pre_vel2(this,at,dt,property,value)
    
    type(thermostat), intent(inout) :: this
    type(atoms),      intent(inout) :: at
    real(dp),         intent(in)    :: dt
    character(*),     intent(in)    :: property
    integer,          intent(in)    :: value

    real(dp) :: R, a(3)
    integer  :: i
    integer, pointer, dimension(:) :: prop_ptr
    real(dp) :: delta_K

    if (.not. assign_pointer(at,property,prop_ptr)) then
       call system_abort('thermostat_post_calc_pre_vel2: cannot find property '//property)
    end if

    select case(this%type)

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

    case(THERMOSTAT_LANGEVIN,THERMOSTAT_LANGEVIN_NPT,THERMOSTAT_LANGEVIN_PR,THERMOSTAT_LANGEVIN_NPT_NB)
     
       ! Add the random acceleration
       R = 2.0_dp*this%gamma*BOLTZMANN_K*this%T/dt

       ! Random numbers may have been used at different rates on different MPI processes:
       ! we must resync the random number if we want the same numbers on each process.
       call system_resync_rng()

       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          a = sqrt(R/at%mass(i))*ran_normal3()
          at%acc(:,i) = at%acc(:,i) + a
       end do

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX


       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

    !case(THERMOSTAT_NOSE_HOOVER)

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX


       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER-THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

    !case(THERMOSTAT_NOSE_HOOVER_LANGEVIN) nothing to be done
       
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN with Ornstein-Uhlenbeck dynamics (Leimkuhler e-mail)
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN_OU)
              
       ! propagate eta (a.k.a. chi) for a full step

       if (this%Q > 0.0_dp) then
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + dt*2.0_dp*delta_K/this%Q
       endif

    end select

  end subroutine thermostat_post_calc_pre_vel2
  
  subroutine thermostat_post_vel2(this,at,dt,property,value,virial)

    type(thermostat), intent(inout) :: this
    type(atoms),      intent(inout) :: at
    real(dp),         intent(in)    :: dt
    character(*),     intent(in)    :: property
    integer,          intent(in)    :: value
    real(dp), dimension(3,3), intent(in), optional :: virial

    real(dp) :: decay, K, volume_p, f_cell, rv_mag, OU_dv(3)
    real(dp), dimension(3,3) :: lattice_p, ke_virial, decay_matrix, decay_matrix_eigenvectors, exp_decay_matrix, random_lattice
    real(dp), dimension(3) :: decay_matrix_eigenvalues
    integer  :: i, j
    integer, pointer, dimension(:) :: prop_ptr
    real(dp) :: delta_K
    real(dp) :: OU_random_dv_mag

    if (.not. assign_pointer(at,property,prop_ptr)) then
       call system_abort('thermostat_post_vel2: cannot find property '//property)
    end if
    
    select case(this%type)


       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN)

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       !Decay the velocities for dt/2 again
       decay = exp(-0.5_dp*(this%gamma+this%eta)*dt)
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif
       
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_NOSE_HOOVER)

       !Decay the velocities again using p_eta for dt/2, and accumulate the (post-decay)
       !kinetic energy (x2) to integrate the 'work' value.
       if (this%Q > 0.0_dp) then
	 decay = exp(-0.5_dp*this%p_eta*dt/this%Q)
       else
	 decay = 1.0_dp
       endif
       K = 0.0_dp
!       dvelo = 0.0_dp
!       ntherm = 0
       do i=1, at%N
          if (prop_ptr(i) /= value) cycle
!	  dvelo = dvelo + norm(at%velo(:,i))*abs(1.0_dp-decay)
!	  ntherm = ntherm + 1
          at%velo(:,i) = at%velo(:,i)*decay
          K = K + at%mass(i)*normsq(at%velo(:,i))
       end do
!       call print("Thermostat " // value //" thermostat_post_vel2 N-H <delta vel>"//(dvelo/real(ntherm,dp)))

       !Calculate new f_eta...
       this%f_eta = 0.0_dp
       do i = 1, at%N
          if (prop_ptr(i) == value) this%f_eta = this%f_eta + at%mass(i)*normsq(at%velo(:,i))
       end do
       this%f_eta = this%f_eta - this%Ndof*BOLTZMANN_K*this%T

       !Propagate p_eta for dt/2
       this%p_eta = this%p_eta + 0.5_dp*this%f_eta*dt

       !Propagate the work for dt/2
       if (this%Q > 0.0_dp) then
	 this%work = this%work + 0.5_dp*this%p_eta*K*dt/this%Q
       endif

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X NOSE-HOOVER-THERMOSTAT_LANGEVIN
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_NOSE_HOOVER_LANGEVIN)
       ! Random numbers may have been used at different rates on different MPI processes:
       ! we must resync the random number if we want the same numbers on each process.
       call system_resync_rng()
       
       !Decay the velocities again using p_eta for dt/2, and accumulate Ek for work integration
       if (this%Q > 0.0_dp) then
	 decay = exp(-0.5_dp*this%p_eta*dt/this%Q)
       else
	 decay = 1.0_dp
       endif
       K = 0.0_dp
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
          K = K + at%mass(i)*normsq(at%velo(:,i))
       end do

       !Propagate work
       if (this%Q > 0.0_dp) then
	 this%work = this%work + 0.5_dp*this%p_eta*K*dt/this%Q
       endif

       !Calculate new f_eta...
       this%f_eta = 0.0_dp
       !Deterministic part:
        do i = 1, at%N
           if (prop_ptr(i) == value) this%f_eta = this%f_eta + at%mass(i)*normsq(at%velo(:,i))
        end do
       this%f_eta = this%f_eta - this%Ndof*BOLTZMANN_K*this%T
       !Stochastic part: 
       this%f_eta = this%f_eta + sqrt(2.0_dp*this%gamma*this%Q*BOLTZMANN_K*this%T/dt)*ran_normal()

       !Propagate p_eta for dt/2 then decay it for dt/2
       this%p_eta = this%p_eta + 0.5_dp*this%f_eta*dt
       this%p_eta = this%p_eta*exp(-0.5_dp*this%gamma*dt)

    case(THERMOSTAT_LANGEVIN_NPT_NB)

       call system_resync_rng()

       ! Leimkuhler+Jones adaptive Langevin
       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       !Decay the velocities for dt/2 again Langevin part
       decay = exp(-0.5_dp*dt*(this%gamma+this%eta))
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       ! Leimkuhler+Jones adaptive Langevin
       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif
       

       !Decay the velocities for dt/2 again barostat part
       decay = exp(-0.5_dp*dt*((1.0_dp + 3.0_dp/this%Ndof)*this%epsilon_v))
       do i = 1, at%N
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       ! half step with epsilon force
       volume_p = cell_volume(at)
       f_cell = sqrt(2.0_dp*BOLTZMANN_K*this%T*this%gamma_p*this%W_p/dt)*ran_normal()
       this%epsilon_f = (trace(virial)+sum(at%mass*sum(at%velo**2,dim=1))-3.0_dp*volume_p*this%p) + &
	  3.0_dp/this%Ndof*sum(at%mass*sum(at%velo**2,dim=1)) + f_cell
       this%epsilon_f = this%epsilon_f + f_cell
       this%epsilon_v = this%epsilon_v + 0.5_dp*dt*this%epsilon_f/this%W_p

       ! half step with epsilon drag
       this%epsilon_v = this%epsilon_v*exp(-0.5_dp*dt*this%gamma_p)

    case(THERMOSTAT_LANGEVIN_NPT)
       ! Random numbers may have been used at different rates on different MPI processes:
       ! we must resync the random number if we want the same numbers on each process.
       call system_resync_rng()

       if( .not. present(virial) ) call system_abort('thermostat_post_vel2: NPT &
       & simulation, but virial has not been passed')

       f_cell = sqrt(2.0_dp*BOLTZMANN_K*this%T*this%gamma_p*this%W_p/dt)*ran_normal()

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       !Decay the velocities for dt/2 again
       decay = exp(-0.5_dp*dt*((this%gamma+this%eta)+(1.0_dp + 3.0_dp/this%Ndof)*this%epsilon_v))
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
       end do

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif
       
       volume_p = cell_volume(at)
       this%epsilon_f = (1.0_dp + 3.0_dp/this%Ndof)*sum(at%mass*sum(at%velo**2,dim=1)) + trace(virial) &
       & - 3.0_dp * volume_p * this%p + f_cell

       this%epsilon_v = ( this%epsilon_v + 0.5_dp * dt * this%epsilon_f / this%W_p ) / &
       & ( 1.0_dp + 0.5_dp * dt * this%gamma_p )

       this%epsilon_r = this%epsilon_r + 0.5_dp*this%epsilon_v*dt
       volume_p = exp(3.0_dp*this%epsilon_r)*this%volume_0
       lattice_p = at%lattice * (volume_p/cell_volume(at))**(1.0_dp/3.0_dp)
       call set_lattice(at,lattice_p, scale_positions=.false.)

       this%epsilon_f2 = f_cell - this%epsilon_v*this%W_p*this%gamma_p

    case(THERMOSTAT_LANGEVIN_PR)

       if( .not. present(virial) ) call system_abort('thermostat_post_vel2: NPT Parrinello-Rahman&
       & simulation, but virial has not been passed')

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       else
	  this%eta = 0.0_dp
       endif

       !Decay the velocities for dt/2 again
       decay_matrix = -0.5_dp*dt*( (this%gamma+this%eta)*matrix_one + this%lattice_v + trace(this%lattice_v)*matrix_one/this%Ndof )
       decay_matrix = ( decay_matrix + transpose(decay_matrix) ) / 2.0_dp ! Making sure the matrix is exactly symmetric
       call diagonalise(decay_matrix,decay_matrix_eigenvalues,decay_matrix_eigenvectors)
       exp_decay_matrix = matmul( decay_matrix_eigenvectors, matmul( diag(exp(decay_matrix_eigenvalues)), transpose(decay_matrix_eigenvectors) ) )
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = matmul(exp_decay_matrix,at%velo(:,i))
          !at%velo(:,i) = at%velo(:,i) + matmul(decay_matrix,at%velo(:,i))
       end do

       if (this%Q > 0.0_dp) then
	  ! propagate eta (Jones and Leimkuhler chi) dt/4
	  delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	  this%eta = this%eta + 0.5_dp*dt*delta_K/this%Q
       endif
       
       do i = 1, 3
          do j = 1, 3
             random_lattice(j,i) = sqrt(2.0_dp*BOLTZMANN_K*this%T*this%gamma_p*this%W_p/dt)*ran_normal()
          enddo
       enddo
       random_lattice = ( random_lattice + transpose(random_lattice) ) / 2.0_dp

       volume_p = cell_volume(at)
       ke_virial = matmul(at%velo*spread(at%mass,dim=1,ncopies=3),transpose(at%velo))
       this%lattice_f = ke_virial + virial - this%p*volume_p*matrix_one + trace(ke_virial)*matrix_one/this%Ndof + random_lattice

       this%lattice_v = ( this%lattice_v + 0.5_dp*dt*this%lattice_f / this%W_p ) / ( 1.0_dp + 0.5_dp * dt * this%gamma_p )

       lattice_p = at%lattice + 0.5_dp * dt * matmul(this%lattice_v,at%lattice)
       call set_lattice(at,lattice_p, scale_positions=.false.)

       this%lattice_f2 = random_lattice - this%gamma_p * this%lattice_v * this%W_p

    case(THERMOSTAT_NPH_ANDERSEN)

       if( .not. present(virial) ) call system_abort('thermostat_post_vel2: THERMOSTAT_NPH &
       & simulation, but virial has not been passed')

       !Decay the velocities for dt/2 again
       decay = exp(-0.5_dp*dt*(1.0_dp + 3.0_dp/this%Ndof)*this%epsilon_v)
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay
       end do
       
       volume_p = cell_volume(at)
       this%epsilon_f = (1.0_dp + 3.0_dp/this%Ndof)*sum(at%mass*sum(at%velo**2,dim=1)) + trace(virial) &
       & - 3.0_dp * volume_p * this%p

       this%epsilon_v = ( this%epsilon_v + 0.5_dp * dt * this%epsilon_f / this%W_p ) 

       this%epsilon_r = this%epsilon_r + 0.5_dp*this%epsilon_v*dt
       volume_p = exp(3.0_dp*this%epsilon_r)*this%volume_0
       lattice_p = at%lattice * (volume_p/cell_volume(at))**(1.0_dp/3.0_dp)
       call set_lattice(at,lattice_p, scale_positions=.false.)

    case(THERMOSTAT_NPH_PR)

       if( .not. present(virial) ) call system_abort('thermostat_post_vel2: THERMOSTAT_NPH Parrinello-Rahman&
       & simulation, but virial has not been passed')

       !Decay the velocities for dt/2 again
       decay_matrix = -0.5_dp*dt*( this%lattice_v + trace(this%lattice_v)*matrix_one/this%Ndof )
       decay_matrix = ( decay_matrix + transpose(decay_matrix) ) / 2.0_dp ! Making sure the matrix is exactly symmetric
       call diagonalise(decay_matrix,decay_matrix_eigenvalues,decay_matrix_eigenvectors)
       exp_decay_matrix = matmul( decay_matrix_eigenvectors, matmul( diag(exp(decay_matrix_eigenvalues)), transpose(decay_matrix_eigenvectors) ) )
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = matmul(exp_decay_matrix,at%velo(:,i))
          !at%velo(:,i) = at%velo(:,i) + matmul(decay_matrix,at%velo(:,i))
       end do

       volume_p = cell_volume(at)
       ke_virial = matmul(at%velo*spread(at%mass,dim=1,ncopies=3),transpose(at%velo))
       this%lattice_f = ke_virial + virial - this%p*volume_p*matrix_one + trace(ke_virial)*matrix_one/this%Ndof

       this%lattice_v = this%lattice_v + 0.5_dp*dt*this%lattice_f / this%W_p
       lattice_p = at%lattice + 0.5_dp * dt * matmul(this%lattice_v,at%lattice)
       call set_lattice(at,lattice_p, scale_positions=.false.)

       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
       !X
       !X THERMOSTAT_LANGEVIN Ornstein-Uhlenbeck
       !X
       !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
    case(THERMOSTAT_LANGEVIN_OU)
       ! Random numbers may have been used at different rates on different MPI processes:
       ! we must resync the random number if we want the same numbers on each process.
       call system_resync_rng()

       !Decay the velocities for dt/2 again by eta (aka chi)
       if (this%eta /= 0.0_dp) then
	  decay = exp(-0.5_dp*this%eta*dt)
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       endif

       !Decay the velocities for dt with gamma
       decay = exp(-this%gamma*dt)
       ! add random force
       OU_random_dv_mag = sqrt(BOLTZMANN_K*this%T*(1.0_dp-exp(-2.0_dp*this%gamma*dt)))
       do i = 1, at%N
          if (prop_ptr(i) /= value) cycle
          at%velo(:,i) = at%velo(:,i)*decay + OU_random_dv_mag/sqrt(at%mass(i))*ran_normal3()
       end do

    case(THERMOSTAT_ALL_PURPOSE)
       !TIME_PROPAG_TEX 90 after second Verlet velocity step (thermostat\_post\_vel2)
       !TIME_PROPAG_TEX 90
       !TIME_PROPAG_TEX 90 $$ \Delta K = 1/2 \left( \sum_i m_i \left| v_i \right|^2 - N_d k_B T \right)~r.v.$$
       !TIME_PROPAG_TEX 90 $$ \chi = \chi + (\tau/2) \Delta K/Q $$
       !TIME_PROPAG_TEX 90 $$ \xi = \xi + (\tau/2) \Delta K/\mu $$
       !TIME_PROPAG_TEX 90 $$ v = v \exp(-0.25 \tau (\chi + \xi)) $$
       !TIME_PROPAG_TEX 90 $$ \xi = \xi \exp\left( -(\tau/2) \gamma_\mathrm{NHL} \right) + \sqrt{k_B T \frac{1-\exp(-\tau \gamma_\mathrm{NHL})}{\mu}}~r.v. $$
       !TIME_PROPAG_TEX 90 $$ v = v \exp(-0.25 \tau (\chi + \xi)) $$
       !TIME_PROPAG_TEX 90 $$ \Delta K = 1/2 \left( \sum_i m_i \left| v_i \right|^2 - N_d k_B T \right) $$
       !TIME_PROPAG_TEX 90 $$ \xi = \xi + (\tau/2) \Delta K/\mu $$
       !TIME_PROPAG_TEX 90 $$ \chi = \chi + (\tau/2) \Delta K/Q $$
       !TIME_PROPAG_TEX 90 $$ v = v \exp(-(\tau/2) \gamma) + \sqrt{k_B T \frac{1-\exp(-\tau\gamma)}{m}} $$
       !TIME_PROPAG_TEX 90

       if (this%gamma > 0.0_dp .or. (this%NHL_gamma > 0.0_dp .and. this%NHL_mu > 0.0_dp)) call system_resync_rng()

       ! Leimkuhler+Jones adaptive Langevin
       ! propagate chi and xi dt/4
       if (this%Q > 0.0_dp .or. this%NHL_mu > 0.0_dp) then
	  if (this%massive) then
	     do i = 1, at%N
		if (prop_ptr(i) /= value) cycle
		delta_K = open_Langevin_delta_K(1, at%mass(i:i), at%velo(1:3,i:i), 3.0_dp, this%T, prop_ptr(i:i), value)
		if (this%Q > 0.0_dp) this%chi_a(i) = this%chi_a(i) + 0.5_dp*dt*delta_K/this%Q
		if (this%NHL_mu > 0.0_dp) this%xi_a(i) = this%xi_a(i) + 0.5_dp*dt*delta_K/this%NHL_mu
	     end do
	  else
	     delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	     if (this%Q > 0.0_dp) this%chi_a = this%chi_a + 0.5_dp*dt*delta_K/this%Q
	     if (this%NHL_mu > 0.0_dp) this%xi_a = this%xi_a + 0.5_dp*dt*delta_K/this%NHL_mu
	  endif
       else
	  this%chi_a = 0.0_dp
	  this%xi_a = 0.0_dp
       endif

       ! quarter step drag part of v
       if (this%massive) then
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     decay = exp(-0.25_dp*dt*(this%chi_a(i)+this%xi_a(i)))
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       else
	  decay = exp(-0.25_dp*dt*(this%chi_a(1)+this%xi_a(1)))
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       endif

       ! Langevin half step for xi (if doing NHL)
       if (this%NHL_mu > 0.0_dp .and. this%NHL_gamma > 0.0_dp) then
	  if (this%massive) then
	     do i = 1, at%N
		if (prop_ptr(i) /= value) cycle
		this%xi_a(i) = this%xi_a(i)*exp(-0.5_dp*dt*this%NHL_gamma) + sqrt(BOLTZMANN_K*this%T*(1.0_dp-exp(-dt*this%NHL_gamma))/this%NHL_mu)*ran_normal()
	     end do
	  else
	     this%xi_a = this%xi_a*exp(-0.5_dp*dt*this%NHL_gamma) + sqrt(BOLTZMANN_K*this%T*(1.0_dp-exp(-dt*this%NHL_gamma))/this%NHL_mu)*ran_normal()
	  endif
       endif

       ! quarter step drag part of v
       if (this%massive) then
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     decay = exp(-0.25_dp*dt*(this%chi_a(i)+this%xi_a(i)))
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       else
	  decay = exp(-0.25_dp*dt*(this%chi_a(1)+this%xi_a(1)))
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     at%velo(:,i) = at%velo(:,i)*decay
	  end do
       endif

       ! Leimkuhler+Jones adaptive Langevin
       ! propagate chi and xi dt/4
       if (this%Q > 0.0_dp .or. this%NHL_mu > 0.0_dp) then
	  if (this%massive) then
	     do i = 1, at%N
		if (prop_ptr(i) /= value) cycle
		delta_K = open_Langevin_delta_K(1, at%mass(i:i), at%velo(1:3,i:i), 3.0_dp, this%T, prop_ptr(i:i), value)
		if (this%Q > 0.0_dp) this%chi_a(i) = this%chi_a(i) + 0.5_dp*dt*delta_K/this%Q
		if (this%NHL_mu > 0.0_dp) this%xi_a(i) = this%xi_a(i) + 0.5_dp*dt*delta_K/this%NHL_mu
	     end do
	  else
	     delta_K = open_Langevin_delta_K(at%N, at%mass, at%velo, this%Ndof, this%T, prop_ptr, value)
	     if (this%Q > 0.0_dp) this%chi_a = this%chi_a + 0.5_dp*dt*delta_K/this%Q
	     if (this%NHL_mu > 0.0_dp) this%xi_a = this%xi_a + 0.5_dp*dt*delta_K/this%NHL_mu
	  endif
       endif

       if (this%gamma > 0.0_dp) then
	  ! Do the Ornstein-Uhlenbeck half step
	  decay=exp(-0.5_dp*this%gamma*dt)
	  rv_mag = sqrt(BOLTZMANN_K*this%T*(1.0_dp-decay**2))
	  do i = 1, at%N
	     if (prop_ptr(i) /= value) cycle
	     OU_dv = rv_mag/sqrt(at%mass(i))*ran_normal3()
	     at%velo(:,i) = decay*at%velo(:,i) + OU_dv
	  end do
       end if

    end select

  end subroutine thermostat_post_vel2

   function open_Langevin_delta_K(N, mass, velo, Ndof, T, prop_ptr, value) result(delta_K)
      integer, intent(in) :: N
      real(dp), intent(in) :: mass(:), velo(:,:)
      real(dp), intent(in) :: Ndof
      real(dp), intent(in) :: T
      integer, intent(in) :: prop_ptr(:), value

      real(dp) :: delta_K

      integer i

       delta_K = 0.0_dp
       do i = 1, N
	  if (prop_ptr(i) == value) delta_K = delta_K + mass(i)*normsq(velo(:,i))
       end do
       delta_K = 0.5_dp*(delta_K - Ndof*BOLTZMANN_K*T)
   end function open_Langevin_delta_K

end module thermostat_module

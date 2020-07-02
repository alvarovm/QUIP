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

#include "error.inc"

!%  Routines to send and receive data via TCP/IP sockets

module SocketTools_module

  use iso_c_binding

  use error_module
  use system_module, only: dp, print, operator(//)
  use extendable_str_module, only: Extendable_Str
  use atoms_types_module, only: Atoms
  use cinoutput_module, only: read, write

  implicit none

  private

  integer, parameter :: MSG_LEN_SIZE = 8
  integer, parameter :: MSG_END_MARKER_SIZE = 5
  character(MSG_END_MARKER_SIZE), parameter :: MSG_END_MARKER = 'done.'
  character(6), parameter :: MSG_INT_FORMAT = 'i6'
  character(6), parameter :: MSG_FLOAT_FORMAT = 'f25.16'
  integer, parameter :: MSG_INT_SIZE = 6, MSG_FLOAT_SIZE = 25
  integer, parameter :: MAX_ATTEMPTS = 5

  interface
     function quip_recv_data(ip, port, client_id, request_code, data, data_len) bind(c)
       use iso_c_binding
       integer(kind=C_INT) :: quip_recv_data
       character(kind=C_CHAR,len=1), dimension(*), intent(in) :: ip
       integer(kind=C_INT), intent(in), value :: port, client_id
       character(kind=C_CHAR,len=1), intent(in) :: request_code
       character(kind=C_CHAR,len=1), dimension(*), intent(in) :: data
       integer(kind=C_INT), intent(inout) :: data_len
     end function quip_recv_data

     function quip_send_data(ip, port, client_id, request_code, data, data_len) bind(c)
       use iso_c_binding
       integer(kind=C_INT) :: quip_send_data
       character(kind=C_CHAR,len=1), dimension(*), intent(in) :: ip
       integer(kind=C_INT), intent(in), value :: port, client_id
       character(kind=C_CHAR,len=1), intent(in) :: request_code
       character(kind=C_CHAR,len=1), dimension(*), intent(in) :: data
       integer(kind=C_INT), intent(in), value :: data_len
     end function quip_send_data
  end interface

  public :: socket_send_reftraj, socket_recv_reftraj, socket_send_xyz, socket_recv_xyz

contains

  subroutine socket_send_reftraj(ip, port, client_id, label, n_atoms, energy, force, virial, error)
    character(*), intent(in) :: ip
    integer, intent(in) :: port, client_id, label, n_atoms
    real(dp), intent(in) :: energy, force(:,:), virial(3,3)
    integer, optional, intent(out) :: error

    character(len_trim(ip)+1) :: c_ip
    integer(kind=C_INT) :: c_port, c_client_id, data_len, status
    character(kind=C_CHAR, len=1), dimension(:), pointer :: data
    character(1024) :: line
    integer i, j, n, attempt

    INIT_ERROR(error)

    c_ip = trim(ip)//C_NULL_CHAR
    c_port = port
    c_client_id = client_id

    ! space for label, n_atoms, 1 energy, 3*N force components and 6 virial components, separated by N+3 newlines
    data_len = 2*MSG_INT_SIZE + MSG_FLOAT_SIZE*(1 + size(force) + 6) + size(force,2)+3
    allocate(data(data_len))
    i = 1

    ! first line is label
    write(line, '('//MSG_INT_FORMAT//')') label
    do j=1,len_trim(line)
       data(i) = line(j:j)
       i = i + 1
    end do
    data(i) = C_NEW_LINE
    i = i + 1

    ! second line is n_atoms
    write(line, '('//MSG_INT_FORMAT//')') n_atoms
    do j=1,len_trim(line)
       data(i) = line(j:j)
       i = i + 1
    end do
    data(i) = C_NEW_LINE
    i = i + 1
   
    ! third line is energy
    write(line, '('//MSG_FLOAT_FORMAT//')') energy
    do j=1,len_trim(line)
       data(i) = line(j:j)
       i = i + 1
    end do
    data(i) = C_NEW_LINE
    i = i + 1

    ! next are the 3*N forces, three components per line
    do n = 1, size(force, 2)
       write(line,'(3'//MSG_FLOAT_FORMAT//')') force(:, n)
       do j=1,len_trim(line)
          data(i) = line(j:j)
          i = i + 1
       end do
       data(i) = C_NEW_LINE
       i = i + 1
    end do

    ! finally the virial, as six components in order xx yy zz xy yz xz (NB: not Voigt order)
    write(line, '(6'//MSG_FLOAT_FORMAT//')') &
         virial(1,1), virial(2,2), virial(3,3), virial(1,2), virial(2,3), virial(1,3)
    do j=1,len_trim(line)
       data(i) = line(j:j)
       i = i + 1
    end do
    ! no newline at end of data

    !write(*,*) 'after packing, i=', i, 'data_len=', data_len
    !write (*,*) 'data='
    !write (*,*) data

    do attempt = 1, MAX_ATTEMPTS
       ! Send data with request code 'R' (results)
       status = quip_send_data(c_ip, c_port, c_client_id, 'R', data, data_len)
       if (status == 0) exit
       call fusleep(100000) ! wait 0.1 seconds
    end do
    if (status /= 0) then
       RAISE_ERROR('fatal error sending data over socket', error)
    end if

    deallocate(data)
    
  end subroutine socket_send_reftraj


  subroutine socket_recv_reftraj(ip, port, client_id, buff_size, label, n_atoms, lattice, frac_pos, error)
    character(*), intent(in) :: ip
    integer, intent(in) :: port, client_id
    integer, intent(in) :: buff_size
    integer, intent(out) :: label, n_atoms
    real(dp), intent(out), dimension(:,:) :: lattice, frac_pos
    integer, optional, intent(out) :: error

    character(len_trim(ip)+1) :: c_ip
    integer(kind=C_INT) :: c_port, c_client_id, data_len, status
    character(kind=C_CHAR, len=1), dimension(:), pointer :: data
    character(1024) :: line
    integer i, j, lineno, attempt

    INIT_ERROR(error)

    c_ip = trim(ip)//C_NULL_CHAR
    c_port = port
    c_client_id = client_id

    data_len = buff_size
    allocate(data(data_len))

    do attempt = 1, MAX_ATTEMPTS
       ! Receive data with request code 'A' (atoms in REFTRAJ format)
       status = quip_recv_data(c_ip, c_port, c_client_id, 'A', data, data_len)
       if (status == 0) exit
       call fusleep(100000) ! wait 0.1 seconds
    end do
    if (status /= 0) then
       RAISE_ERROR('fatal error receiving data over socket', error)
    end if

    i = 1
    lineno = 0
    do while (i < data_len)
       line = ''
       j = 1
       do while (data(i) /= C_NEW_LINE)
          line(j:j) = data(i)
          i = i + 1
          j = j + 1
       end do
       lineno = lineno + 1
       i = i + 1 ! skip the newline character

       if (lineno == 1) then
          read (line,*) label
       else if (lineno == 2) then
          read (line,*) n_atoms
          if (size(frac_pos, 2) < n_atoms) then
             RAISE_ERROR('insufficient space to store received data', error)
          end if
       else if (lineno > 2 .and. lineno <= 5) then
          read (line, *) lattice(lineno-2, :)
       else if (lineno > 5 .and. lineno <= 5+n_atoms) then
          read (line, *) frac_pos(1, lineno-5), frac_pos(2, lineno-5), frac_pos(3, lineno-5)
       else
          RAISE_ERROR('unexpected line '//trim(line), error)
       end if
    end do
    deallocate(data)

  end subroutine socket_recv_reftraj


  subroutine socket_send_xyz(ip, port, client_id, at, error, properties)
    character(*), intent(in) :: ip
    integer, intent(in) :: port, client_id
    type(Atoms), intent(inout) :: at
    integer, optional, intent(out) :: error
    character(len=*), intent(in), optional :: properties

    character(len_trim(ip)+1) :: c_ip
    integer(kind=C_INT) :: c_port, c_client_id, data_len, status
    character(kind=C_CHAR, len=1), dimension(:), pointer :: data
    integer i, j, n, attempt
    type(Extendable_Str) :: estr

    INIT_ERROR(error)

    c_ip = trim(ip)//C_NULL_CHAR
    c_port = port
    c_client_id = client_id

    call write(at, estr=estr, properties=properties) ! write Atoms to extendable str
    ! convert estr to C string
    data_len = estr%len
    allocate(data(data_len))
    do i=1, data_len
       data(i) = estr%s(i)
    end do
    
    do attempt = 1, MAX_ATTEMPTS
       call print('socket_send_xyz() calling quip_send_data attempt='//attempt)
       ! Send data with request code 'Y' (XYZ results)
       status = quip_send_data(c_ip, c_port, c_client_id, 'Y', data, data_len)
       if (status == 0) exit
       call fusleep(100000) ! wait 0.1 seconds
    end do
    if (status /= 0) then
       RAISE_ERROR('fatal error sending data over socket', error)
    end if

    deallocate(data)

  end subroutine socket_send_xyz

  
  subroutine socket_recv_xyz(ip, port, client_id, buff_size, at, error)
    character(*), intent(in) :: ip
    integer, intent(in) :: port, client_id
    integer, intent(in) :: buff_size
    type(Atoms), intent(out) :: at
    integer, optional, intent(out) :: error

    character(len_trim(ip)+1) :: c_ip
    integer(kind=C_INT) :: c_port, c_client_id, data_len, status
    character(kind=C_CHAR, len=1), dimension(:), pointer :: data
    character(len=buff_size) :: fdata
    integer i, attempt

    INIT_ERROR(error)

    c_ip = trim(ip)//C_NULL_CHAR
    c_port = port
    c_client_id = client_id

    data_len = buff_size
    allocate(data(data_len))

    do attempt = 1, MAX_ATTEMPTS
       call print('socket_recv_xyz() calling quip_recv_data attempt='//attempt)
       ! Receive data with request code 'X' (receive atoms in XYZ format)
       status = quip_recv_data(c_ip, c_port, c_client_id, 'X', data, data_len)
       if (status == 0) exit
       call fusleep(100000) ! wait 0.1 seconds
    end do
    if (status /= 0) then
       RAISE_ERROR('fatal error receiving data over socket', error)
    end if
    ! convert from C to Fortran string
    do i=1, data_len
       fdata(i:i) = data(i)
    end do
    !call print('recieved data <'//fdata//'>')
    ! read from fdata string into Atoms in XYZ format
    call read(at, str=fdata, error=error)
    PASS_ERROR(error)
    deallocate(data)

  end subroutine socket_recv_xyz


end module SocketTools_Module

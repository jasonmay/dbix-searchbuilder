#!/usr/bin/perl -w

use strict;

=head1 VARIABLES

=head2 @SupportedDrivers

Array of all supported DBD drivers.

=cut

our @SupportedDrivers = qw(
	Informix
	mysql
	mysqlPP
	ODBC
	Oracle
	Pg
	SQLite
	Sybase
);

=head2 @AvailableDrivers

Array that lists only drivers from supported list
that user has installed.

=cut

our @AvailableDrivers = grep { eval "require DBD::". $_ } @SupportedDrivers;

=head1 FUNCTIONS

=head2 get_handle

Returns new DB specific handle. Takes one argument DB C<$type>.
Other arguments uses to construct handle.

=cut

sub get_handle
{
	my $type = shift;
	my $class = 'DBIx::SearchBuilder::Handle::'. $type;
	eval "require $class";
	die $@ if $@;
	my $handle;
	$handle = $class->new( @_ );
	return $handle;
}

=head2 handle_to_driver

Returns driver name which gets from C<$handle> object argument.

=cut

sub handle_to_driver
{
	my $driver = ref($_[0]);
	$driver =~ s/^.*:://;
	return $driver;
}

=head2 connect_handle

Connects C<$handle> object to DB.

=cut

sub connect_handle
{
	my $call = "connect_". lc handle_to_driver( $_[0] );
	return unless defined &$call;
	goto &$call;
}

sub connect_sqlite
{
	my $handle = shift;
	return $handle->Connect(
		Driver => 'SQLite',
		Database => File::Spec->catfile(File::Spec->tmpdir(), "sb-test.$$")
	);
}

sub connect_mysql
{
	my $handle = shift;
	return $handle->Connect(
		Driver => 'mysql',
		Database => $ENV{'SB_TEST_MYSQL'},
		User => $ENV{'SB_TEST_MYSQL_USER'} || 'root',
		Password => $ENV{'SB_TEST_MYSQL_PASS'} || '',
	);
}

sub connect_pg
{
	my $handle = shift;
	return $handle->Connect(
		Driver => 'Pg',
		Database => $ENV{'SB_TEST_PG'},
		User => $ENV{'SB_TEST_PG_USER'} || 'postgres',
		Password => $ENV{'SB_TEST_PG_PASS'} || '',
	);
}

=head2 should_test

Checks environment for C<SB_TEST_*> variables.
Returns true if specified DB back-end should be tested.
Takes one argument C<$driver> name.

=cut

sub should_test
{
	my $driver = shift;
	return 1 if lc $driver eq 'sqlite';
	my $env = 'SB_TEST_'. uc $driver;
	return $ENV{$env};
}

=head2 had_schema

Returns true if C<$class> has schema for C<$driver>.

=cut

sub has_schema
{
	my ($class, $driver) = @_;
	my $method = 'schema_'. lc $driver;
	return UNIVERSAL::can( $class, $method );
}

=head2 init_schema

Takes C<$class> and C<$handle> and inits schema by calling
C<schema_$driver> method of the C<$class>.
Returns last C<DBI::st> on success or last return value of the
SimpleQuery method on error.

=cut

sub init_schema
{
	my ($class, $handle) = @_;
	my $call = "schema_". lc handle_to_driver( $handle );
	my $schema = $class->$call();
	$schema = ref( $schema )? $schema : [$schema];
	my $ret;
	foreach my $query( @$schema ) {
		$ret = $handle->SimpleQuery( $query );
		return $ret unless UNIVERSAL::isa( $ret, 'DBI::st' );
	}
	return $ret;
}

=head2 cleanup_schema

Takes C<$class> and C<$handle> and inits schema by calling
C<cleanup_schema_$driver> method of the C<$class> if method exists.
Always returns undef.

=cut

sub cleanup_schema
{
	my ($class, $handle) = @_;
	my $call = "cleanup_schema_". lc handle_to_driver( $handle );
	return unless UNIVERSAL::can( $class, $call );
	my $schema = $class->$call();
	$schema = ref( $schema )? $schema : [$schema];
	foreach my $query( @$schema ) {
		eval { $handle->SimpleQuery( $query ) };
	}
}

1;
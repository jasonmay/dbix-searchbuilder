#$Header: /home/jesse/DBIx-SearchBuilder/history/SearchBuilder/Handle/Pg.pm,v 1.8 2001/07/27 05:23:29 jesse Exp $
# Copyright 1999-2001 Jesse Vincent <jesse@fsck.com>

package DBIx::SearchBuilder::Handle::Pg;
use strict;

use vars qw($VERSION @ISA $DBIHandle $DEBUG);
use base qw(DBIx::SearchBuilder::Handle);
use Want qw(want howmany);

use strict;

=head1 NAME

  DBIx::SearchBuilder::Handle::Pg - A Postgres specific Handle object

=head1 SYNOPSIS


=head1 DESCRIPTION

This module provides a subclass of DBIx::SearchBuilder::Handle that 
compensates for some of the idiosyncrasies of Postgres.

=head1 METHODS

=cut


=head2 Connect

Connect takes a hashref and passes it off to SUPER::Connect;
Forces the timezone to GMT
it returns a database handle.

=cut
  
sub Connect {
    my $self = shift;
    
    $self->SUPER::Connect(@_);
    $self->SimpleQuery("SET TIME ZONE 'GMT'");
    $self->SimpleQuery("SET DATESTYLE TO 'ISO'");
    $self->AutoCommit(1);
    return ($DBIHandle); 
}


=head2 Insert

Takes a table name as the first argument and assumes
that the rest of the arguments are an array of key-value
pairs to be inserted.

In case of insert failure, returns a L<Class::ReturnValue>
object preloaded with error info.

=cut


sub Insert {
    my $self  = shift;
    my $table = shift;
    my %args  = (@_);

    my $sth = $self->SUPER::Insert( $table, %args );
    return $sth unless $sth;

    if ( $args{'id'} || $args{'Id'} ) {
        $self->{'id'} = $args{'id'} || $args{'Id'};
        return ( $self->{'id'} );
    }

    my $sequence_name = $self->IdSequenceName($table);
    unless ($sequence_name) { return ($sequence_name) }   # Class::ReturnValue
    my $seqsth = $self->dbh->prepare(
        qq{SELECT CURRVAL('} . $sequence_name . qq{')} );
    $seqsth->execute;
    $self->{'id'} = $seqsth->fetchrow_array();

    return ( $self->{'id'} );
}

=head2 InsertQueryString

Postgres sepcific overriding method for
L<DBIx::SearchBuilder::Handle/InsertQueryString>.

=cut

sub InsertQueryString {
    my $self = shift;
    my ($query_string, @bind) = $self->SUPER::InsertQueryString( @_ );
    $query_string .= ' DEFAULT VALUES' unless $query_string =~ /\bVALUES\s+\(/i;
    return ($query_string, @bind);
}

=head2 IdSequenceName TABLE

Takes a TABLE name and returns the name of the  sequence of the primary key for that table.

=cut

sub IdSequenceName {
    my $self  = shift;
    my $table = shift;

    return $self->{'_sequences'}{$table} if (exists $self->{'_sequences'}{$table});
    #Lets get the id of that row we just inserted
    my $seq;
    my $colinfosth = $self->dbh->column_info( undef, undef, lc($table), '%' );
    while ( my $foo = $colinfosth->fetchrow_hashref ) {

        # Regexp from DBIx::Class's Pg handle. Thanks to Marcus Ramberg
        if ( defined $foo->{'COLUMN_DEF'}
            && $foo->{'COLUMN_DEF'}
            =~ m!^nextval\(+'"?([^"']+)"?'(::(?:text|regclass)\))+!i )

        {
            return $self->{'_sequences'}{$table} = $1;
        }

    }
            my $ret = Class::ReturnValue->new();
            $ret->as_error(
                errno   => '-1',
                message => "Found no sequence for $table",
                do_backtrace => undef
            );
            return ( $ret->return_value );

}



=head2 BinarySafeBLOBs

Return undef, as no current version of postgres supports binary-safe blobs

=cut

sub BinarySafeBLOBs {
    my $self = shift;
    return(undef);
}


=head2 ApplyLimits STATEMENTREF ROWS_PER_PAGE FIRST_ROW

takes an SQL SELECT statement and massages it to return ROWS_PER_PAGE starting with FIRST_ROW;


=cut

sub ApplyLimits {
    my $self = shift;
    my $statementref = shift;
    my $per_page = shift;
    my $first = shift;

    my $limit_clause = '';

    if ( $per_page) {
        $limit_clause = " LIMIT ";
        $limit_clause .= $per_page;
        if ( $first && $first != 0 ) {
            $limit_clause .= " OFFSET $first";
        }
    }

   $$statementref .= $limit_clause; 

}


=head2 _MakeClauseCaseInsensitive FIELD OPERATOR VALUE

Takes a field, operator and value. performs the magic necessary to make
your database treat this clause as case insensitive.

Returns a FIELD OPERATOR VALUE triple.

=cut

sub _MakeClauseCaseInsensitive {
    my $self     = shift;
    my $field    = shift;
    my $operator = shift;
    my $value    = shift;


    if ($value =~ /^['"]?\d+['"]?$/) { # we don't need to downcase numeric values
        	return ( $field, $operator, $value);
    }

    if ( $operator =~ /LIKE/i ) {
        $operator =~ s/LIKE/ILIKE/ig;
        return ( $field, $operator, $value );
    }
    elsif ( $operator =~ /=/ ) {
	if (howmany() >= 4) {
        	return ( "LOWER($field)", $operator, $value, "LOWER(?)"); 
	} 
	# RT 3.0.x and earlier  don't know how to cope with a "LOWER" function 
	# on the value. they only expect field, operator, value.
	# 
	else {
		return ( "LOWER($field)", $operator, lc($value));

	}
    }
    else {
        $self->SUPER::_MakeClauseCaseInsensitive( $field, $operator, $value );
    }
}

=head2 DistinctQuery STATEMENTREF

takes an incomplete SQL SELECT statement and massages it to return a DISTINCT result set.

=cut

sub DistinctQuery {
    my $self = shift;
    my $statementref = shift;
    my $sb = shift;
    my $table = $sb->Table;

    if ($sb->_OrderClause =~ /(?<!main)\./) {
        # If we are ordering by something not in 'main', we need to GROUP
        # BY and adjust the ORDER_BY accordingly
        local $sb->{group_by} = [@{$sb->{group_by} || []}, {FIELD => 'id'}];
        local $sb->{order_by} = [map {($_->{ALIAS} and $_->{ALIAS} ne "main") ? {%{$_}, FIELD => "min(".$_->{FIELD}.")"}: $_} @{$sb->{order_by}}];
        my $group = $sb->_GroupClause;
        my $order = $sb->_OrderClause;
        $$statementref = "SELECT main.* FROM ( SELECT main.id FROM $$statementref $group $order ) distinctquery, $table main WHERE (main.id = distinctquery.id)";
    } else {
        $$statementref = "SELECT DISTINCT main.* FROM $$statementref";
        $$statementref .= $sb->_GroupClause;
        $$statementref .= $sb->_OrderClause;
    }
}

1;

__END__

=head1 SEE ALSO

DBIx::SearchBuilder, DBIx::SearchBuilder::Handle

=cut


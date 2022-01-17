use strict;
use warnings;
use 5.14.2;

use Cwd;
use File::Temp qw[tempdir];
use JSON::PP;
use Test::Exception;
use Test::More;    # see done_testing()

use Zonemaster::Engine;

=head1 ENVIRONMENT

=head2 TARGET

Set the database to use.
Can be C<SQLite>, C<MySQL> or C<PostgreSQL>.
Default to C<SQLite>.

=head2 ZONEMASTER_RECORD

If set, the data from the test is recorded to a file. Otherwise the data is
loaded from a file.

=cut

# Use the TARGET environment variable to set the database to use
# default to SQLite
my $db_backend = $ENV{TARGET};
if ( not $db_backend ) {
    $db_backend = 'SQLite';
} elsif ( $db_backend !~ /^(?:SQLite|MySQL|PostgreSQL)$/ ) {
    BAIL_OUT( "Unsupported database backend: $db_backend" );
}

diag "database: $db_backend";

my $tempdir = tempdir( CLEANUP => 1 );

my $datafile = q{t/test01.data};
if ( not $ENV{ZONEMASTER_RECORD} ) {
    die q{Stored data file missing} if not -r $datafile;
    Zonemaster::Engine->preload_cache( $datafile );
    Zonemaster::Engine->profile->set( q{no_network}, 1 );
    diag "not recording";
} else {
    diag "recording";
}

# Require Zonemaster::Backend::RPCAPI.pm test
use_ok( 'Zonemaster::Backend::RPCAPI' );

use_ok( 'Zonemaster::Backend::Config' );

my $cwd = cwd();

my $config = Zonemaster::Backend::Config->parse( <<EOF );
[DB]
engine = $db_backend

[MYSQL]
host     = localhost
user     = travis_zm
password = travis_zonemaster
database = travis_zonemaster

[POSTGRESQL]
host     = localhost
user     = travis_zonemaster
password = travis_zonemaster
database = travis_zonemaster

[SQLITE]
database_file = $tempdir/zonemaster.sqlite

[LANGUAGE]
locale = en_US

[PUBLIC PROFILES]
test_profile=$cwd/t/test_profile.json
EOF

# Create Zonemaster::Backend::RPCAPI object
my $backend = Zonemaster::Backend::RPCAPI->new(
    {
        dbtype => $db_backend,
        config => $config,
    }
);
isa_ok( $backend, 'Zonemaster::Backend::RPCAPI' );

if ( $db_backend eq 'SQLite' ) {
    # create a new memory SQLite database
    ok( $backend->{db}->create_db(), "$db_backend database created");
}

my $dbh = $backend->{db}->dbh;

# Create the agent
use_ok( 'Zonemaster::Backend::TestAgent' );
my $agent = Zonemaster::Backend::TestAgent->new( { dbtype => "$db_backend", config => $config } );
isa_ok($agent, 'Zonemaster::Backend::TestAgent', 'agent');


subtest 'add test user' => sub {
    is( $backend->add_api_user( { username => "zonemaster_test", api_key => "zonemaster_test's api key" } ), 1, 'API add_api_user success');

    my $user_check_query = q/SELECT * FROM users WHERE username = 'zonemaster_test'/;
    is( scalar( $dbh->selectrow_array( $user_check_query ) ), 1 ,'API add_api_user user created' );
};

# add a new test to the db
my $frontend_params_1 = {
    client_id      => 'Unit Test',         # free string
    client_version => '1.0',               # free version like string
    domain         => 'afnic.fr',          # content of the domain text field
    ipv4           => JSON::PP::true,                   # 0 or 1, is the ipv4 checkbox checked
    ipv6           => JSON::PP::true,                   # 0 or 1, is the ipv6 checkbox checked
    profile        => 'test_profile',    # the id if the Test profile listbox

    nameservers => [                       # list of the nameserves up to 32
        { ns => 'ns1.nic.fr' },       # key values pairs representing nameserver => namesterver_ip
        { ns => 'ns2.nic.fr', ip => '192.134.4.1' },
    ],
    ds_info => [                                  # list of DS/Digest pairs up to 32
        { keytag => 11627, algorithm => 8, digtype => 2, digest => 'a6cca9e6027ecc80ba0f6d747923127f1d69005fe4f0ec0461bd633482595448' },
    ],
};

my $hash_id;

# This is the first test added to the DB, its 'id' is 1
my $test_id = 1;
subtest 'add a first test' => sub {
    $hash_id = $backend->start_domain_test( $frontend_params_1 );

    ok( $hash_id, "API start_domain_test OK" );
    is( length($hash_id), 16, "Test has a 16 characters length hash ID (hash_id=$hash_id)" );

    my ( $test_id_db, $hash_id_db ) = $dbh->selectrow_array( "SELECT id, hash_id FROM test_results WHERE id=?", undef, $test_id );
    is( $test_id_db, $test_id , 'API start_domain_test -> Test inserted in the DB' );
    is( $hash_id_db, $hash_id , 'Correct hash_id in database' );

    # test test_progress API
    is( $backend->test_progress( { test_id => $hash_id } ), 0 , 'API test_progress -> OK');
};

diag "running the agent on test $hash_id";
$agent->run( $hash_id ); # blocking call


subtest 'API calls' => sub {
    my $progress = $backend->test_progress( { test_id => $hash_id } );
    is( $progress, 100 , 'test_progress' );

    subtest 'get_test_results' => sub {
        my $res = $backend->get_test_results( { id => $hash_id, language => 'en_US' } );
        is( $res->{id}, $test_id, 'Retrieve the correct "id"' );
        is( $res->{hash_id}, $hash_id, 'Retrieve the correct "hash_id"' );
        ok( defined $res->{params}, 'Value "params" properly defined' );
        ok( defined $res->{creation_time}, 'Value "creation_time" properly defined' );
        ok( defined $res->{results}, 'Value "results" properly defined' );
        cmp_ok( scalar( @{ $res->{results} } ), '>', 1, 'The test has some results' );
    };

    subtest 'get_test_params' => sub {
        my $res = $backend->get_test_params( { test_id => $hash_id } );
        is( $res->{domain}, $frontend_params_1->{domain}, 'Retrieve the correct "domain" value' );
        is( $res->{profile}, $frontend_params_1->{profile}, 'Retrieve the correct "profile" value' );
        is( $res->{client_id}, $frontend_params_1->{client_id}, 'Retrieve the correct "client_id" value' );
        is( $res->{client_version}, $frontend_params_1->{client_version}, 'Retrieve the correct "client_version" value' );
        is( $res->{ipv4}, $frontend_params_1->{ipv4}, 'Retrieve the correct "ipv4" value' );
        is( $res->{ipv6}, $frontend_params_1->{ipv6}, 'Retrieve the correct "ipv6" value' );
        is_deeply( $res->{nameservers}, $frontend_params_1->{nameservers}, 'Retrieve the correct "nameservers" value' );
        is_deeply( $res->{ds_info}, $frontend_params_1->{ds_info}, 'Retrieve the correct "ds_info" value' );
    };
};

# start a second test with IPv6 disabled
$frontend_params_1->{ipv6} = 0;
$hash_id = $backend->start_domain_test( $frontend_params_1 );
diag "running the agent on test $hash_id";
$agent->run($hash_id);

my $offset = 0;
my $limit  = 10;
my $test_history =
    $backend->get_test_history( { frontend_params => $frontend_params_1, offset => $offset, limit => $limit } );
diag explain( $test_history );
is( scalar( @$test_history ), 2, 'Two tests created' );

is( length($test_history->[0]->{id}), 16, 'Test 0 has 16 characters length hash ID' );
is( length($test_history->[1]->{id}), 16, 'Test 1 has 16 characters length hash ID' );

subtest 'mock another client' => sub {
    $frontend_params_1->{client_id} = 'Another Client';
    $frontend_params_1->{client_version} = '0.1';

    my $hash_id = $backend->start_domain_test( $frontend_params_1 );
    ok( $hash_id, "API start_domain_test OK" );
    is( length($hash_id), 16, "Test has a 16 characters length hash ID (hash_id=$hash_id)" );

    # check that we reuse one of the previous test
    subtest 'check that previous test was reused' => sub {
        my %ids = map { $_->{id} => 1 } @$test_history;
        ok ( exists( $ids{$hash_id} ), "Has the same hash than previous test" );
    };

    subtest 'check test_params values' => sub {
        my $res = $backend->get_test_params( { test_id => "$hash_id" } );
        my @keys_res = sort( keys %$res );
        my @keys_params = sort( keys %$frontend_params_1 );

        is_deeply( \@keys_res, \@keys_params, "All keys are in database" );

        foreach my $key (@keys_res) {
            if ( $key eq "client_id" or $key eq "client_version" ) {
                isnt( $frontend_params_1->{$key}, $res->{$key}, "but value for key '$key' is different (which is fine)" );
            }
            else {
                is_deeply( $frontend_params_1->{$key}, $res->{$key}, "same value for key '$key'" );
            }
        }
    };
    #diag "...but values for client_id and client_version are different (which is fine)";

};

subtest 'check historic tests' => sub {
    # Verifies that delegated and undelegated tests are coded correctly when started
    # and that the filter option in "get_test_history" works correctly

    my $domain          = 'xa';
    # Non-batch for "start_domain_test":
    my $params_un1      = { # undelegated, non-batch
        domain          => $domain,
        nameservers     => [
            { ns => 'ns2.nic.fr', ip => '192.134.4.1' },
            ],
    };
    my $params_un2      = { # undelegated, non-batch
        domain          => $domain,
        ds_info         => [
            { keytag => 11627, algorithm => 8, digtype => 2, digest => 'a6cca9e6027ecc80ba0f6d747923127f1d69005fe4f0ec0461bd633482595448' },
            ],
    };
    my $params_dn1 = { # delegated, non-batch
        domain          => $domain,
    };
    # Batch for "add_batch_job"
    my $domain2         = 'xb';
    my $params_ub1      = { # undelegated, batch
        domains         => [ $domain, $domain2 ],
        test_params     => {
            nameservers => [
                { ns => 'ns2.nic.fr', ip => '192.134.4.1' },
                ],
        },
    };
    my $params_ub2      = { # undelegated, batch
        domains         => [ $domain, $domain2 ],
        test_params     => {
            ds_info     => [
                { keytag => 11627, algorithm => 8, digtype => 2, digest => 'a6cca9e6027ecc80ba0f6d747923127f1d69005fe4f0ec0461bd633482595448' },
                ],
        },
    };
    my $params_db1      = { # delegated, batch
        domains         => [ $domain, $domain2 ],
    };
    # The batch jobs, $params_ub1, $params_ub2 and $params_db1, cannot be run from here due to limitation in the API. See issue #827.

    foreach my $param ($params_un1, $params_un2, $params_dn1) {
        my $testid = $backend->start_domain_test( $param );
        ok( $testid, "API start_domain_test ID OK" );
        diag "running the agent on test $testid";
        $agent->run( $testid );
        is( $backend->test_progress( { test_id => $testid } ), 100 , 'API test_progress -> Test finished' );
    };

    my $test_history_delegated = $backend->get_test_history(
        {
            filter => 'delegated',
            frontend_params => {
                domain => $domain,
            }
        } );
    my $test_history_undelegated = $backend->get_test_history(
        {
            filter => 'undelegated',
            frontend_params => {
                domain => $domain,
            }
        } );

    # diag explain( $test_history_delegated );
    is( scalar( @$test_history_delegated ), 1, 'One delegated test created' );
    # diag explain( $test_history_undelegated );
    is( scalar( @$test_history_undelegated ), 2, 'Two undelegated tests created' );
};

if ( $ENV{ZONEMASTER_RECORD} ) {
    Zonemaster::Engine->save_cache( $datafile );
}

done_testing();

if ( $db_backend eq 'SQLite' ) {
    my $dbfile = $dbh->sqlite_db_filename;
    if ( -e $dbfile and -M $dbfile < 0 and -o $dbfile ) {
        unlink $dbfile;
    }
}

use strict;
use warnings;

use Test::More tests => 1;

use File::Path;
use FindBin;
use Test::TCP;
use Try::Tiny;

use Catalyst::Devel 1.0;
use File::Copy::Recursive;

# Run a single test by providing it as the first arg
my $single_test = shift;

my $tmpdir = "$FindBin::Bin/../../t/tmp";

# clean up
rmtree $tmpdir if -d $tmpdir;

# create a TestApp and copy the test libs into it
mkdir $tmpdir;
chdir $tmpdir;
system( $^X, "-I$FindBin::Bin/../../lib", "$FindBin::Bin/../../script/catalyst.pl", 'TestApp' );
chdir "$FindBin::Bin/..";
File::Copy::Recursive::dircopy( '../t/lib', '../t/tmp/TestApp/lib' ) or die;

# remove TestApp's tests
rmtree '../t/tmp/TestApp/t' or die;

# spawn the standalone HTTP server
my $port = empty_port;

my $pid = fork;
if ($pid) {
    # parent.
    print "Waiting for server to start...\n";
    wait_port_timeout($port, 30);
} elsif ($pid == 0) {
    # child process
    unshift @INC, "$tmpdir/TestApp/lib", "$FindBin::Bin/../../lib";
    require TestApp;

    my $psgi_app = TestApp->_wrapped_legacy_psgi_app(TestApp->psgi_app);
    Plack::Loader->auto(port => $port)->run($psgi_app);

    exit 0;
} else {
    die "fork failed: $!";
}

# run the testsuite against the HTTP server
$ENV{CATALYST_SERVER} = "http://localhost:$port";

chdir '..';

my $return;
if ( $single_test ) {
    $return = system( "$^X -Ilib/ $single_test" );
}
else {
    $return = prove(grep { $_ ne '..' } glob('t/aggregate/live_*.t'));
}

# shut it down
kill 'INT', $pid;

# clean up
rmtree "$FindBin::Bin/../../t/tmp" if -d "$FindBin::Bin/../../t/tmp";

is( $return, 0, 'live tests' );

sub wait_port_timeout {
    my ($port, $timeout) = @_;

    # wait_port waits for 10 seconds
    for (1 .. int($timeout / 10)) { # meh, good enough.
        try { wait_port $port; 1 } and return;
    }

    die "Server did not start within $timeout seconds";
}

sub prove {
    my (@tests) = @_;
    if (!(my $pid = fork)) {
        require TAP::Harness;

        my $aggr = -e '.aggregating';
        my $harness = TAP::Harness->new({
            ($aggr ? (test_args => \@tests) : ()),
            lib => ['lib'],
        });

        my $aggregator = $aggr
            ? $harness->runtests('t/aggregate.t')
            : $harness->runtests(@tests);

        exit $aggregator->has_errors ? 1 : 0;
    } else {
        waitpid $pid, 0;
        return $?;
    }
}

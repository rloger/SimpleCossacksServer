# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl SimpleCossacksServer.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use strict;
use warnings;
use Test::More;
use Net::EmptyPort;

BEGIN { use_ok('SimpleCossacksServer') };

my $port = Net::EmptyPort::empty_port();

my $server = new_ok(SimpleCossacksServer => [
  config_file => './etc/simple-cossacks-server.conf',
  port => $port,
]);

ok(eval { $server->start() }, "start server");

done_testing();
#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.


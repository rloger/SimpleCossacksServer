package SimpleCossacksServer::CommandController;
use Mouse;
BEGIN { extends 'GSC::Server::CommandController' }
use SimpleCossacksServer::CommandController::Open;
use String::Escape();

sub login : Command {
  my($self, $h, $lgdta) = @_;
  $h->push_command( LW_show => ':GW|open&enter.dcml');
}

sub open : Command {
  my($self, $h, $url, $params) = @_;
  s/\s+//, s/\0$// for $url;
  my %P;
  if($params) {
    $params =~ s/\0//;
    %P = ( $params =~ m{\G(\w+)=(.*?)(?:\^(?=\w+=)|$)}gs );
  }
  my $method = ( $url =~ s/\.dcml//r );
  if(SimpleCossacksServer::CommandController::Open->public($method)) {
    SimpleCossacksServer::CommandController::Open->$method($h, \%P);
  } else {
    $h->log->warn("open $url" . ($params ? " $params" : "") .  " not found");
    SimpleCossacksServer::CommandController::Open->_default($h, \%P);
  }
}

sub echo : Command {
  my($self, $h, @args) = @_;
  $h->push_command( LW_echo => @args );
}

sub GETTBL : Command {
  my($self, $h, $name, $num, $rows_pack) = @_;
  s/\0$// for $name, $num;
  my @rows_ctl_sum = unpack 'L*', $rows_pack;
  my %rows_ctl_sum = map { $_ => 1 } @rows_ctl_sum;
  my(@dtbl, @tbl);
  my $rooms = $h->server->data->{dbtbl}{$name};
  my $rooms_by_ctlsum = $h->server->data->{rooms_by_ctlsum};
  for my $sum (@rows_ctl_sum) {
    push @dtbl, $sum unless $rooms_by_ctlsum->{$sum};
  }
  for my $room (@$rooms) {
    unless($rows_ctl_sum{ $room->{ctlsum} }) {
      push @tbl, $room->{row};
    }
  }
  $h->push_command( LW_dtbl => map{"$_\0"} $name, pack 'L*', @dtbl);
  $h->push_command( LW_tbl => map{"$_\0"} $name, scalar(@tbl), map {@$_} @tbl );
}

sub alive : Command {
  my($self, $h) = @_;
  my $id = $h->connection->data->{id} or return;
  my $connection = $h->connection;
  $h->server->data->{alive_timers}{ $id } = AnyEvent->timer( after => 150, cb => sub {
    $self->not_alive($h, $connection);
  } );
}

sub stats : Command {
  my($self, $h) = @_;
  $self->alive($h);
}

sub leave : Command {
  my($self, $h) = @_;
  my $room = $h->server->leave_room( $h->connection->data->{id} ) if $h->connection->data->{id};
  delete $h->server->data->{alive_timers}{ $h->connection->data->{id} };
  if($room) {
    if($room->{host_id} == $h->connection->data->{id}) {
      $h->log->info($h->connection->log_message . " " . $h->req->ver . " #leave his room $room->{id} $room->{title}");
    } else {
      $h->log->info($h->connection->log_message . " " . $h->req->ver . " #leave room $room->{id} $room->{title}");
    }
  } else {
    $h->log->warn($h->connection->log_message . " " . $h->req->ver . " have not room for leave");
  }
}

sub start : Command {
  my($self, $h) = @_;
  my $room = $h->server->start_room( $h->connection->data->{id} );
  if($room) {
    if($room->{host_id} == $h->connection->data->{id}) {
      $h->log->info($h->connection->log_message . " " . $h->req->ver . " #start game $room->{id} $room->{title}");
    } else {
      $h->log->info($h->connection->log_message . " " . $h->req->ver . " #start his game $room->{id} $room->{title}");
    }
  } else {
     $h->log->warn($h->connection->log_message . " have not game for start"); 
  }
}

sub upfile  : Command {}
sub endgame : Command {}
sub unsync  : Command {}

sub _before {
  my($self, $h) = @_;
  my $cmd  = $h->req->cmd;
  my $args = $h->req->argsref;
  my $message = $h->connection->log_message;
  my $win = $h->req->win;
  $win =~ s/\0$//;
  $message .= ' ' . $h->req->ver . ' ' . $h->req->lang . ' ' . $h->req->num . ' "' . String::Escape::printable($win) . '"';
  if($cmd eq 'upfile') {
    $message .= " -$cmd " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args[0..1];
    my($offset, $size, $buffer) = unpack "LLA*", $args->[2];
    $message .= " offset=$offset,size=$size,realsize=" . length($buffer);
    $message .= " " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args[3..$#$args] if $#$args >= 3;
  } elsif($cmd eq 'alive') {
    $message .= " -$cmd ";
    $message .= uc unpack 'H*', $args->[0];
    $message .= " " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args[1..$#$args] if $#$args >= 1;
  } elsif($cmd eq 'stats') { 
    my @all = unpack "C S H14 SSLLLLLLSSH*", $args->[0];
    $_ //= '' for @all;
    my($u1, $n, $u2, $sc, $pp, $w, $g, $s, $f, $i, $c, $p, $u, $tail) = @all;
    $message .= " -$cmd ";
    $message .= " u1=$u1,u2=$u2,n=$n,sc=$sc,pp=$pp,w=$w,g=$g,s=$s,f=$f,i=$i,c=$c,p=$p,u=$u";
    $message .= ",tail=$tail" if defined($tail) && length($tail) > 0;
    $message .= " " . uc unpack 'H*', $args->[0];
    $message .= " " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args[1..$#$args] if $#$args >= 1;
  } elsif($cmd eq 'GETTBL') {
    $message .= " -$cmd " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args[0..1];
    $message .= ' rows=' . (join ':', map {sprintf "%08X", $_} unpack 'L*', $args->[2]);
    $message .= " " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args[3..$#$args] if $#$args >= 3;
  } else {
    $message .= " -$cmd " . join " ", map { '"' . String::Escape::printable($_) . '"' } @$args;
  }
  $h->log->info($message);
}

sub not_alive {
  my($self, $h, $connection) = @_;
  my $id = $connection->data->{id};
  my $room = $h->server->leave_room( $id );
  delete $h->server->data->{alive_timers}{ $id };
  if($room) {
    if($room->{host_id} = $id) {
      $h->log->info($connection->log_message . " " . $h->req->ver . " #not alive in his room $room->{id} $room->{title}");
    } else {
      $h->log->info($connection->log_message . " " . $h->req->ver . " #not alive in room $room->{id} $room->{title}");      
    }
  }
}

__PACKAGE__->meta->make_immutable();

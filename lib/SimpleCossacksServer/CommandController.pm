package SimpleCossacksServer::CommandController;
use Mouse;
BEGIN { extends 'GSC::Server::CommandController' }
use SimpleCossacksServer::CommandController::Open;
use String::Escape();
use JSON();

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
  my $hide_started = !$h->connection->data->{dev};
  for my $sum (@rows_ctl_sum) {
    push @dtbl, $sum if !$rooms_by_ctlsum->{$sum} || $hide_started && $rooms_by_ctlsum->{$sum}->{started};
  }
  $rooms = [grep {!$_->{started}} @$rooms] if $hide_started;
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
  $h->server->data->{alive_timers}{ $id } = AnyEvent->timer( after => 150, cb => sub {
    $self->not_alive($h, $id);
  } );
}

sub stats : Command {
  my($self, $h) = @_;
  $self->alive($h);
}

sub leave : Command {
  my($self, $h) = @_;
  if($h->connection->data->{id}) {
    my $room = $h->server->leave_room( $h->connection->data->{id} );
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
  } else {
    $h->log->warn($h->connection->log_message . " " . $h->req->ver . " no id for live room");
  }
}

sub start : Command {
  my($self, $h, $sav, $map, $players_count, @players_list) = @_;
  my $room = $h->server->start_room( $h->connection->data->{id} );
  if($room) {
    if($room->{host_id} == $h->connection->data->{id}) {
      $h->log->info($h->connection->log_message . " " . $h->req->ver . " #start his game $room->{id} $room->{title}");
    } else {
      $h->log->info($h->connection->log_message . " " . $h->req->ver . " #start game $room->{id} $room->{title}");
    }
  } else {
     $h->log->info($h->connection->log_message . " " . $h->req->ver . " #start game ?unknown?");
     $h->log->warn($h->connection->log_message . " have not game for start"); 
  }
  if($room) { # установка таймаутов
    for my $player_id (keys %{$room->{players}}) {
      $h->server->data->{alive_timers}{ $player_id } = AnyEvent->timer( after => 150, cb => sub {
        $self->not_alive($h, $player_id);
      } );
    }
  }
  if($h->connection->data->{account}) { # отправка статы в wcl/lcn аккаунт
    s/\0$// for $sav, $map, $players_count, @players_list;
    $_ = int($_) for $players_count, @players_list;
    my $post_room;
    if($room) {
      my @fields = qw<id title max_players players_count level ctime>;
      @$post_room{@fields} = @$room{@fields};
      $_ = int($_) for @$post_room{qw<id max_players players_count level ctime>};
    } else {
      $post_room = { id => $room->{id}, lost => JSON::true };
    }

    $post_room->{map} = $map;
    $post_room->{save_from} = int($1) if $sav && $sav =~ /^sav:\[(\d+)\]$/;

    my $i = 0;
    while(@players_list && $i < $players_count) {
      my($player_id, $nation, $theam, $color) = splice(@players_list, 0, 4);
      $player_id = unpack 'L', pack 'l', $player_id;
      my $post_player;
      if(my $player = $h->server->data->{players}{$player_id}) {
        my @fields = qw<id nick connected_at>;
        @$post_player{@fields} = @$player{@fields};
        $_ = int($_) for @$post_player{qw<id connected_at>};
        if($player->{account}) {
          my @fields = qw<type profile id>;
          @{$post_player->{account}}{@fields} = @{$player->{account}}{@fields};
        }
      } else {
        my $post_player = { id => $player_id, lost => JSON::true };
      }
      @$post_player{qw<nation theam color>} = ($nation, $theam, $color);
      push @{$post_room->{players}}, $post_player;
      $i++;
    }

    $h->server->post_account_action($h, 'start', $post_room);
  }
}

sub endgame : Command {
    my($self, $h, $game_id, $player_id, $result) = @_;
    ($_) = /(-?\d+)/ for $game_id, $player_id, $result;
    $player_id = unpack 'L', pack 'l', $player_id;
    my $id = $h->connection->data->{id};
    my $short_player_id = $player_id - 0x7FFFFFFF + 1;
    my $nick_name = ($h->server->data->{players}{$player_id} ? $h->server->data->{players}{$player_id}{nick} : '.') . ":$short_player_id";
    my $result_str = $result == 1 ? 'loose' :
        $result == 2 ? 'win' :
        $result == 5 ? 'disconnect' :
        "?$result?"
    ;
    my $room = $h->server->data->{rooms_by_id}{ $game_id };
    $h->log->info(
        $h->connection->log_message . " " . $h->req->ver . " #send game result: $nick_name $result_str in "
        . ($room && $id && $room->{host_id} == $id ? "his " : "" )
        . "game $game_id"
        . ($room ? " $room->{title}" : "")
    );
}
sub upfile  : Command {}
sub unsync  : Command {}

sub _before {
  my($self, $h) = @_;
  my $cmd  = $h->req->cmd;
  my $args = $h->req->argsref;
  my $message = $h->connection->log_message;
  my $win = $h->req->win;
  my $key = $h->req->key;
  s/\0$// for $win, $key;
  $message .= ' ' . $h->req->ver . ' ' . $h->req->lang . ' ' . $h->req->num . ' "' . String::Escape::printable($win) . '" "' . String::Escape::printable($key) . '"';
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
    my @all = unpack "LCLC SSLLLLLLSSH*", $args->[0];
    $_ //= '' for @all;
    my($t, $pc, $id, $st, $sc, $pp, $w, $g, $s, $f, $i, $c, $p, $u, $tail) = @all;
    $message .= " -$cmd";
    $message .= " t=$t,pc=$pc,id=$id,st=$st,sc=$sc,pp=$pp,w=$w,g=$g,s=$s,f=$f,i=$i,c=$c,p=$p,u=$u";
    $message .= ",tail=$tail" if defined($tail) && length($tail) > 0;
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
  my($self, $h, $id) = @_;
  my $connection = $h->server->connection_class->connection_by_pid($id);
  delete $h->server->data->{alive_timers}{ $id };
  my $room = $h->server->leave_room( $id );
  if($room && $connection) {
    $h->log->info($connection->log_message . " " . $h->req->ver . " #not alive in" . ($room->{host_id} == $id ? " his" : "") . " room $room->{id} $room->{title}"); 
  }
}

sub url :Command {
  my($self, $h, $url) = @_;
  $h->push_command(LW_time => 0, "open:$url");
}

__PACKAGE__->meta->make_immutable();

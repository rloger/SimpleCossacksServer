package SimpleCossacksServer::CommandController::Open;
use Mouse;

my @PUBLIC = qw[
  enter try_enter startup games new_room_dgl reg_new_room 
  join_game join_pl_cmd user_details users_list direct direct_ping 
  direct_join room_info_dgl
];


my %PUBLIC = map { $_ => 1 } @PUBLIC;
sub public {
  my($self, $method) = @_;
  return $PUBLIC{$method};
}

sub enter {
  my($self, $h, $url, $p) = @_;
  $h->show('enter.cml');
}

sub try_enter {
  my($self, $h, $p) = @_;
  my $nick = $p->{NICK};
  if(!defined($nick) || $nick eq '') {
    $h->show('error_enter.cml', { error_text => 'Enter nick' });
  } elsif($nick !~ /^[\[\]_\w-]+$/) {
    $h->show('error_enter.cml', { error_text => 'Bad character in nick' });
  } else {
    my $g = $h->server->data;
    my $id;
    unless($h->connection->data->{id}) {
      if(@{$g->{ids}}) {
        push @{$g->{ids}}, $id = $g->{ids}->[-1] + 1;
      } else {
        push @{$g->{ids}}, $id = 0x7FFFFFFF;
      }
      $h->connection->data->{id} = $id;
    } else {
      $id = $h->connection->data->{id};
    }
    $h->connection->data->{nick} = $nick;
    $h->log->info($h->connection->log_message . " " . $h->req->ver . " #enter");
    $g->{nicks}{$id} = $nick;
    $h->show('ok_enter.cml', { P => $p, id => $id});
  }
}

sub startup {
  my($self, $h, $p) = @_;
  $h->show('startup.cml');
}

sub games {
  my $self = shift;
  $self->startup(@_);
}

sub new_room_dgl {
  my($self, $h, $p) = @_;
  if(!$p->{ASTATE}) {
    $self->_error($h, "You can not create or join room!\nYou are already participate in some room\nPlease disconnect from that room first to create a new one");
  } else {
    $h->show('new_room_dgl.cml');
  }
}

sub reg_new_room {
  my($self, $h, $p) = @_;
  if(!$p->{ASTATE}) {
    $self->_error($h, "You can not create or join room!\nYou are already participate in some room\nPlease disconnect from that room first to create a new one");
  } elsif($p->{VE_TITLE} eq '') {
    $h->show('confirm_dgl.cml', {
      header  => "Error",
      text    => "Illegal title!\nPress Edit button to check title",
      ok_text => "Edit",
      command => "GW|open&new_room_dgl.dcml&ASTATE=<%ASTATE>",
    });
  } elsif(!$h->connection->data->{id} || !$h->connection->data->{nick}) {
    $self->_error($h, "Your was disconnected from the server. Enter again.");
  } else {
    my $player_id = $h->connection->data->{id};
    $h->server->leave_room( $player_id );
    my $rooms = ( $h->server->data->{dbtbl}{ "ROOMS_V" . $h->req->ver } //= [] );
    $h->server->data->{last_room} ||= 1;
    my $room_id = ++$h->server->data->{last_room};
    my $level = $p->{VE_LEVEL} == 3 ? 'Hard' : $p->{VE_LEVEL} == 2 ? 'Normal' : $p->{VE_LEVEL} == 1 ? 'Easy' : '';
    my $row = [ $room_id, $p->{VE_TITLE}, $h->connection->data->{nick}, ($h->is_american_conquest ? $p->{VE_TYPE} : ()), $level, "1/".($p->{VE_MAX_PL}+2), $h->req->ver, $h->connection->int_ip ];
    my $ctlsum = $h->server->_room_control_sum($row);
    my $room = {
      row            => $row,
      id             => $room_id,
      title          => $p->{VE_TITLE},
      password       => $p->{VE_PASSWD} // '',
      host_id        => $player_id,
      host_addr      => $h->connection->ip,
      host_addr_int  => $h->connection->int_ip,
      players_count  => 1,
      players        => { $player_id => time },
      max_players    => $p->{VE_MAX_PL} + 2,
      passwd         => $p->{VE_PASSWD},
      ver            => $h->req->ver,
      level          => int($p->{VE_LEVEL}),
      ctime          => time,
      ctlsum         => $ctlsum,
    };
    push @$rooms, $room;
    $h->server->data->{rooms_by_ctlsum}->{ $room->{ctlsum} }  = $room;
    $h->server->data->{rooms_by_player}->{ $room->{host_id} } = $room;
    $h->server->data->{rooms_by_id}->{ $room->{id} }          = $room;
    my $connection = $h->connection;
    $h->server->data->{alive_timers}{ $player_id } = AnyEvent->timer( after => 150, cb => sub {
      $h->server->command_controller($h)->not_alive($h, $connection);
    } );
    $h->log->info($h->connection->log_message . " " . $h->req->ver . " #create room $room->{id} $room->{title}" );
    $h->show('reg_new_room.cml', { id => ($p->{VE_TYPE} ? "HB" : "") . $room_id, name => $room->{title}, max_pl => $room->{max_players} });
  }
}

sub room_info_dgl {
  my($self, $h, $p) = @_;
  if($p->{VE_RID} !~ /^\d+$/) {
    $h->push_command( LW_show => "<NGDLG>\n<NGDLG>");
    return;
  }
  my $room = $h->server->data->{rooms_by_id}{ $p->{VE_RID} };
  unless($room->{id}) {
    $self->_error($h, "The room is closed");
    return;
  }
  $h->show('room_info_dgl.cml', { room => $room, room_time => $self->_time_interval($room->{ctime}) });
}

sub _time_interval {
    my($self, $ctime) = @_;
    my $time = time - $ctime;
    my @tm;

    my $d = int($time / 86400);
    $time %= 86400;
    push @tm, "${d}d" if $d;

    my $h = int($time / 3600);
    $time %= 3600;
    push @tm, "${h}h" if $h;
    return join " ", @tm if $d;

    my $m = int($time / 60);
    $time %= 60;
    push @tm, "${m}m" if $m;
    return join " ", @tm if $h || $m >= 10;

    my $s = $time;
    push @tm, "${s}s" if $s;
    return @tm ? join(" ", @tm) : "0s";
}

sub join_game {
  my($self, $h, $p) = @_;
  if($p->{VE_RID} !~ /^\d+$/) {
    $h->push_command( LW_show => "<NGDLG>\n<NGDLG>");
    return;
  }
  my $room = $h->server->data->{rooms_by_id}{ $p->{VE_RID} };
  $self->_join_to_room($h, $room, $p->{ASTATE}, $p->{VE_PASSWD} // '');
}

sub _join_to_room {
  my($self, $h, $room, $astate, $password) = @_;
  if(!$h->connection->data->{id} || !$h->connection->data->{nick}) {
    $self->_error($h, "Your was disconnected from the server. Enter again.");
    return;
  }
  if(!$astate) {
    $self->_error($h, "You can not create or join room!\nYou are already participate in some room\nPlease disconnect from that room first to create a new one");
    return;
  }
  if(!$room || $room->{started}) {
    $self->_error($h, "You can not join this room!\nThe room is closed");
    return;
  }
  if($room->{players_count} >= $room->{max_players}) {
    $self->_error($h, "You can not join this room!\nThe room is full");
    return;
  }
  if($room->{password} ne '' && $password ne $room->{password}) {
    $h->show('confirm_password_dgl.cml', { id => $room->{id} });
    return;
  }
  my $player_id = $h->connection->data->{id};
  $h->server->leave_room( $player_id );
  $h->server->data->{rooms_by_player}{ $player_id } = $room;
  delete $h->server->data->{rooms_by_ctlsum}->{ $room->{ctlsum} };
  $room->{players}{ $player_id } = 1;
  $room->{players}{ $player_id } = time;
  $room->{players_count}++;
  $room->{row}[-3] = $room->{players_count} . "/" . $room->{max_players};
  $room->{ctlsum} = $h->server->_room_control_sum($room->{row});
  $h->server->data->{rooms_by_ctlsum}->{ $room->{ctlsum} } = $room;
  my $connection = $h->connection;
  $h->push_command( LW_gvar => (
        '%CG_GAMEID'   => $room->{id},
        '%CG_MAXPL'    => $room->{max_players},
        '%CG_GAMENAME' => $room->{title},
        '%COMMAND'     => 'JGAME',
        '%CG_IP'       => $room->{host_addr},
  ));
  $h->log->info($h->connection->log_message . " " . $h->req->ver . " #join room $room->{id} $room->{title}" );
}

sub user_details {
  my($self, $h, $p) = @_;
  if($p->{ID} >= 0x7FFFFFFF) {
    $self->_alert($h, "Player Server", "This is cossacs-server.net player")
  } else {
    $self->_alert($h, "Player Server", "This is gsc game server player")
  }
}

sub join_pl_cmd {
  my($self, $h, $p) = @_;
  unless($p->{VE_PLAYER} >= 0x7FFFFFFF) {
    $self->_error($h, "This is GSC game server player");
    return;
  } else {
    $h->push_empty, return if $h->connection->data->{id} && $h->server->data->{rooms_by_player}{ $h->connection->data->{id} };
    my $room = $h->server->data->{rooms_by_player}{ $p->{VE_PLAYER} };
    $self->_join_to_room($h, $room, 1, '');
  }
}

sub users_list {
  my($self, $h, $p) = @_;
  $self->_error($h, "Not imlemented");
}

sub _default {
  my($self, $h, $p) = @_;
  $self->_error($h, "Page Not Found");
}

sub _alert {
  my($self, $h, $header, $text) = @_;
  $h->show('alert_dgl.cml', { text => $text, header => $header });
}

sub _error {
  my($self, $h, $text) = @_;
  $h->show('alert_dgl.cml', { text => $text, header => 'Error' })
}

__PACKAGE__->meta->make_immutable();

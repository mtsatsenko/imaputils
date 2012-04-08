#!/usr/bin/perl

# $Header: /mhub4/sources/imap-tools/imapcopy.pl,v 1.45 2012/03/15 12:35:11 rick Exp $

#######################################################################
#   Program name    imapcopy.pl                                       #
#   Written by      Rick Sanders                                      #
#                                                                     #
#   Description                                                       #
#                                                                     #
#   imapcopy is a utility for copying a user's messages from one      #
#   IMAP server to another.                                           #
#                                                                     #
#   imapcopy is called like this:                                     #
#      ./imapcopy -S host1/user1/password1 -D host2/user2/password2   # 
#                                                                     #
#   Optional arguments:                                               #
#	-d debug                                                      #
#       -I show IMAP protocol exchanges                               #
#       -L logfile                                                    #
#       -m mailbox list (copy only certain mailboxes,see usage notes) #
#       -r reset the \DELETE flag on copied messages                  #
#       -p <root mailbox> put copied mailboxes under a root mbx       #
#       -M <file> mailbox mapping (eg, src:inbox -> dst:inbox_copied) #
#       -i initialize mailbox (remove existing msgs first)            #
#       -U run in "update" mode
#   Run imapcopy.pl -h to see complete set of arguments.              #
#######################################################################

use Socket;
use FileHandle;
use Fcntl;
use Getopt::Std;
use IO::Socket;

#################################################################
#            Main program.                                      #
#################################################################

   init();

   #  Get list of all messages on the source host
   #
   connectToHost($sourceHost, \$src)   or exit;
   login($sourceUser,$sourcePwd, $sourceHost, $src, $srcMethod) or exit;
   namespace( $src, \$srcPrefix, \$srcDelim, $opt_x );

   connectToHost( $destHost, \$dst ) or exit;
   login( $destUser,$destPwd, $destHost, $dst, $dstMethod ) or exit;
   namespace( $dst, \$dstPrefix, \$dstDelim, $opt_y );

   @mbxs = getMailboxList( $srcPrefix, $src );

   #  Exclude certain mbxs if that's what the user wants
   exclude_mbxs( \@mbxs ) if $excludeMbxs;

   map_mbx_names( \%mbx_map, $srcDelim, $dstDelim );

   if ( $archive_mbx ) {
      #  Create an archive mbx on the source to receive copies of messsages
      createMbx( $archive_mbx, $src ) unless mbxExists( $archive_mbx, $src);
   }

   $total=$mbxs_processed = 0;
   my $delete_msg_list;
   $num_mbxs = $#mbxs + 1;
   Log("Number of mailboxes to process: $num_mbxs");
   foreach $srcmbx ( @mbxs ) {
        ###  encode( \$srcmbx );
        next if $srcmbx eq $archive_mbx;
        $archived=0;
        $mbxs_processed++;
        if ( $verbose ) {
           $line = "Processing $srcmbx " . '(' . $mbxs_processed . '/' . $num_mbxs . ')';
           Log("$line");
        }
        $dstmbx = mailboxName( $srcmbx,$srcPrefix,$srcDelim,$dstPrefix,$dstDelim );
        $LAST = "$dstmbx";
        createMbx( $dstmbx, $dst ) unless mbxExists( $dstmbx, $dst);

        if ( $include_nosel_mbxs ) {
           #  If a mailbox was 'Noselect' on the src but the user wants
           #  it created as a regular folder on the dst then do so.  They
           #  don't hold any messages so after creating them we don't need
           #  to do anything else.
           next if $nosel_mbxs{"$srcmbx"};
        }

        selectMbx( $dstmbx, $dst );

        if ( $update ) {
           getMsgIdList( $dstmbx, \%DST_MSGS, $dst );
        }

        init_mbx( $dstmbx, $dst ) if $init_mbx;

        $checkpoint  = "$srcmbx|$sourceHost|$sourceUser|$sourcePwd|";
        $checkpoint .= "$destHost|$destUser|$destPwd";
	
        if ( $sent_after ) {
           getDatedMsgList( $srcmbx, $sent_after, \@msgs, $src, 'EXAMINE' );
        } else {
           getMsgList( $srcmbx, \@msgs, $src, 'EXAMINE' );
        }

        my $msgcount = $#msgs + 1;
        Log("   Copying $msgcount messages in $srcmbx mailbox") if $verbose;
        if ( $msgcount == 0 ) {
           Log("   $srcmbx mailbox is empty");
           next;
        }

        $copied=0;
        foreach $_ ( @msgs ) {
           alarm $timeout;
           ($msgnum,$date,$flags,$msgid) = split(/\|/, $_);

           Log("msgnum=$msgnum,msgid=$msgid") if $debug;

           if ( $update ) {
              #  Don't insert the message if it already exists
              next if $DST_MSGS{"$msgid"};
           }

           #  Strip off TZ offset if it exists
           $date =~ s/\((.+)\)$//;
           $date =~ s/\s+$//g;

           $LAST = "$dstmbx|$msgnum";
           next unless fetchMsg( $msgnum, \$message, $srcmbx, $src );

           # $message =~ /Message-Id: (.+)/i;
           # Log("message has msgid = $1");
           alarm 0;

           if ( $conn_timed_out ) {
              Log("$sourceHost timed out");
              reconnect( $checkpoint, $src );
              $conn_timed_out = 0;
              next;
           }
           next unless $message;

           alarm $timeout;

           $copied++ if insertMsg( $dst, $dstmbx, *message, $flags, $date );

           if ( $archive_mbx ) {
              #  Put a copy of the message in it too
              if ( insertMsg( $src, $archive_mbx, *message, $flags, $date ) ) {
                 $archived++;
                 if ( $rem_src_msgs ) {
                    $delete_msg_list .= "$msgnum ";
                 }
              }
           }

           if ( $copied/100 == int($copied/100)) {
              Log("   Copied $copied messages so far") if $verbose;
           }

           alarm 0;

           if ( $conn_timed_out ) {
              Log("$destHost timed out");
              reconnect( $checkpoint, $dst );
              $conn_timed_out = 0;
              next;
           }

        }
        $total += $copied;
        if ( $use_utf7 ) {
           $dstmbx = Unicode::IMAPUtf7::imap_utf7_decode( $dstmbx );
        }
        if ( $verbose ) {
           $line = "   Copied $copied messages to $dstmbx ";
           $line .=  '(' . $mbxs_processed . '/' . $num_mbxs . ')';
           Log( "$line ");
        } else {
           Log("   Copied $copied messages to $dstmbx");
        }

        if ( $archive_mbx ) {
           Log("   Copied $archived messages to $archive_mbx mailbox");
           if ( $rem_src_msgs ) {
              #  Remove the messages from the source mailbox
              Log("Removing messages from $srcmbx on source");
              delete_msg_list( $delete_msg_list, $srcmbx, $src );
              expungeMbx( $srcmbx, $src );
           }
        }
   }

   Log("Copied $total total messages");
   logout( $src );
   logout( $dst );

   exit;


sub init {

   $os = $ENV{'OS'};

   processArgs();

   #  Open the logFile
   #
   if ( $logfile ) {
      if ( !open(LOG, ">> $logfile")) {
         print STDOUT "Can't open $logfile: $!\n";
         exit;
      } 
      select(LOG); $| = 1;
   }
   Log("$0 starting");

   #  Determine whether we have SSL support via openSSL and IO::Socket::SSL
   $ssl_installed = 1;
   eval 'use IO::Socket::SSL';
   if ( $@ ) {
      $ssl_installed = 0;
   }

   #  Set up signal handling
   $SIG{'ALRM'} = 'signalHandler';
   $SIG{'HUP'}  = 'signalHandler';
   $SIG{'INT'}  = 'signalHandler';
   $SIG{'TERM'} = 'signalHandler';
   $SIG{'URG'}  = 'signalHandler';

}

#
#  sendCommand
#
#  This subroutine formats and sends an IMAP protocol command to an
#  IMAP server on a specified connection.
#

sub sendCommand {

my $fd = shift;
my $cmd = shift;

    print $fd "$cmd\r\n";

    Log (">> $cmd") if $showIMAP;
}

#
#  readResponse
#
#  This subroutine reads and formats an IMAP protocol response from an
#  IMAP server on a specified connection.
#

sub readResponse {
    
my $fd = shift;

    $response = <$fd>;
    chop $response;
    $response =~ s/\r//g;
    push (@response,$response);
    Log ("<< $response") if $showIMAP;
}

#
#  Log
#
#  This subroutine formats and writes a log message to STDERR.
#

sub Log {
 
my $str = shift;

   #  If a logfile has been specified then write the output to it
   #  Otherwise write it to STDOUT

   if ( $logfile ) {
      ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
      if ($year < 99) { $yr = 2000; }
      else { $yr = 1900; }
      $line = sprintf ("%.2d-%.2d-%d.%.2d:%.2d:%.2d %s\n",
		     $mon + 1, $mday, $year + $yr, $hour, $min, $sec,$str);
      print LOG "$line";
   } 
   print STDOUT "$str\n" unless $quiet_mode;

}


sub createMbx {

my $mbx  = shift;
my $conn = shift;

   #  Create the mailbox if necessary

   sendCommand ($conn, "1 CREATE \"$mbx\"");
   while ( 1 ) {
      readResponse ($conn);
      last if $response =~ /^1 OK/i;
      last if $response =~ /already exists/i;
      if ( $response =~ /^1 NO|^1 BAD|^\* BYE/ ) {
         Log ("Error creating $mbx: $response");
         last;
      }
      if ( $response eq ''  or $response =~ /^1 NO/ ) {
         Log ("unexpected CREATE response: >$response<");
         Log("response is NULL");
         resume();
         last;
      }
      
   } 

}

#  insertMsg
#
#  This routine inserts a message into a user's mailbox
#
sub insertMsg {

local ($conn, $mbx, *message, $flags, $date) = @_;
local ($lenx);

   $lenx = length($message);

   Log("   Inserting message") if $debug;
   my $mb = $lenx/1000000;

   if ( $max_size and $mb > $max_size ) {
      commafy( \$lenx );
      Log("   Skipping message because its size ($lenx) exceeds the $max_size MB limit");
      return;
   }

   $totalBytes = $totalBytes + $lenx;
   $totalMsgs++;

   $flags = flags( $flags );

   fixup_date( \$date );

   sendCommand ($conn, "1 APPEND \"$mbx\" ($flags) \"$date\" \{$lenx\}");
   readResponse ($conn);
   if ( $response !~ /^\+/ ) {
       Log ("1 unexpected APPEND response: >$response<");
       if ( $response eq ''  or $response =~ /^1 NO/ ) {
          Log("response is NULL");
          resume();
          next;
       }
       # next;
       push(@errors,"Error appending message to $mbx for $user");
       return 0;
   }

   print $conn "$message\r\n";

   undef @response;
   while ( 1 ) {
       readResponse ($conn);
       if ( $response =~ /^1 OK/i ) {
	   last;
       }
       elsif ( $response !~ /^\*/ ) {
	   Log ("unexpected APPEND response: $response");
	   # next;
	   return 0;
       }
   }

   return 1;
}

#  Make a connection to a IMAP host

sub connectToHost {

my $host = shift;
my $conn = shift;

   Log("Connecting to $host") if $debug;
   
   ($host,$port) = split(/:/, $host);
   $port = 143 unless $port;

   # We know whether to use SSL for ports 143 and 993.  For any
   # other ones we'll have to figure it out.
   $mode = sslmode( $host, $port );

   if ( $mode eq 'SSL' ) {
      unless( $ssl_installed == 1 ) {
         warn("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         Log("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         exit;
      }
      Log("Attempting an SSL connection") if $debug;
      $$conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        $error = IO::Socket::SSL::errstr();
        Log("Error connecting to $host: $error");
        exit;
      }
   } else {
      #  Non-SSL connection
      Log("Attempting a non-SSL connection") if $debug;
      $$conn = IO::Socket::INET->new(
         Proto           => "tcp",
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        Log("Error connecting to $host:$port: $@");
        warn "Error connecting to $host:$port: $@";
        exit;
      }
   } 
   Log("Connected to $host on port $port");

}

sub sslmode {

my $host = shift;
my $port = shift;
my $mode;

   #  Determine whether to make an SSL connection
   #  to the host.  Return 'SSL' if so.

   if ( $port == 143 ) {
      #  Standard non-SSL port
      return '';
   } elsif ( $port == 993 ) {
      #  Standard SSL port
      return 'SSL';
   }
      
   unless ( $ssl_installed ) {
      #  We don't have SSL installed on this machine
      return '';
   }

   #  For any other port we need to determine whether it supports SSL

   my $conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
    );

    if ( $conn ) {
       close( $conn );
       $mode = 'SSL';
    } else {
       $mode = '';
    }

   return $mode;
}

#  trim
#
#  remove leading and trailing spaces from a string
sub trim {
 
local (*string) = @_;

   $string =~ s/^\s+//;
   $string =~ s/\s+$//;

   return;
}


#  login
#
#  login in at the source host with the user's name and password
#
sub login {

my $user = shift;
my $pwd  = shift;
my $host = shift;
my $conn = shift;
my $method = shift;

   Log("Authenticating to $host as $user");
   if ( uc( $method ) eq 'CRAM-MD5' ) {
      #  A CRAM-MD5 login is requested
      Log("login method $method");
      my $rc = login_cram_md5( $user, $pwd, $conn );
      return $rc;
   }

   #  Otherwise do a PLAIN login

   sendCommand ($conn, "1 LOGIN $user \"$pwd\"");
   while (1) {
	readResponse ( $conn );
	last if $response =~ /^1 OK/i;
	if ($response =~ /^1 NO|^1 BAD|^\* BYE/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
	}
   }
   Log("Logged in as $user") if $debug;

   return 1;
}


sub login_cram_md5 {

my $user = shift;
my $pwd  = shift;
my $conn = shift;

   sendCommand ($conn, "1 AUTHENTICATE CRAM-MD5");
   while (1) {
        readResponse ( $conn );
        last if $response =~ /^\+/;
        if ($response =~ /^1 NO|^1 BAD|^\* BYE/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
        }
   }

   my ($challenge) = $response =~ /^\+ (.+)/;

   Log("challenge $challenge") if $debug;
   $response = cram_md5( $challenge, $user, $pwd );
   Log("response $response") if $debug;

   sendCommand ($conn, $response);
   while (1) {
        readResponse ( $conn );
        last if $response =~ /^1 OK/i;
        if ($response =~ /^1 NO|^1 BAD|^\* BYE/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
        }
   }
   Log("Logged in as $user") if $debug;

   return 1;
}

#  logout
#
#  log out from the host
#
sub logout {

my $conn = shift;

   undef @response;
   sendCommand ($conn, "1 LOGOUT");
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^1 OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected LOGOUT response: $response");
		last;
	}
   }
   close $conn;
   return;
}

#  getMailboxList
#
#  get a list of the user's mailboxes from the source host
#
sub getMailboxList {

my $prefix = shift;
my $conn   = shift;
my @mbxs;

   #  Get a list of the user's mailboxes
   #

   Log("Get list of user's mailboxes",2) if $debugMode;

   if ( $mbxList ) {
      foreach $mbx ( split(/,/, $mbxList) ) {
         $mbx = $prefix . $mbx if $prefix;
         if ( $opt_R ) {
            # Get all submailboxes under the ones specified
            $mbx .= '*';
            @mailboxes = listMailboxes( $mbx, $conn);
            push( @mbxs, @mailboxes );
         } else {
            push( @mbxs, $mbx );
         }
      }
   } else {
      #  Get all mailboxes
      @mbxs = listMailboxes( '*', $conn);
   }

   return @mbxs;
}

#  exclude_mbxs
#
#  Exclude certain mailboxes from the list if the user
#  has provided an exclude list with the -e argument

sub exclude_mbxs {

my $mbxs = shift;
my @new_list;
my %exclude;

   foreach my $exclude ( split(/,/, $excludeMbxs ) ) {
      $exclude{"$exclude"} = 1;
   }
   foreach my $mbx ( @$mbxs ) {
      next if $exclude{"$mbx"};
      push( @new_list, $mbx );
   }

   @$mbxs = @new_list;

}

#  listMailboxes
#
#  Get a list of the user's mailboxes
#
sub listMailboxes {

my $mbx  = shift;
my $conn = shift;

   sendCommand ($conn, "1 LIST \"\" \"$mbx\"");
   undef @response;
   while ( 1 ) {
        &readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
                last;
        }
        elsif ( $response !~ /^\*/ ) {
                &Log ("unexpected response: $response");
                return 0;
        }
   }

   @mbxs = ();
   for $i (0 .. $#response) {
        $response[$i] =~ s/\s+/ /;
        if ( $response[$i] =~ /"$/ ) {
           $response[$i] =~ /\* LIST \((.*)\) "(.+)" "(.+)"/i;
           $mbx = $3;
        } elsif ( $response[$i] =~ /\* LIST \((.*)\) NIL (.+)/i ) {
           $mbx   = $2;
        } else {
           $response[$i] =~ /\* LIST \((.*)\) "(.+)" (.+)/i;
           $mbx = $3;
        }
        $mbx =~ s/^\s+//;  $mbx =~ s/\s+$//;

        if ($response[$i] =~ /NOSELECT/i) {
           if ( $include_nosel_mbxs ) {
              $nosel_mbxs{"$mbx"} = 1;
           } else {
              Log("$mbx is set NOSELECT, skipping it") if $debug;
              next;
           }
        }
        if ($mbx =~ /^\./) {
                # Skip mailboxes starting with a dot
                next;
        }
        push ( @mbxs, $mbx ) if $mbx ne '';
   }

   return @mbxs;
}

#  getMsgList
#
#  Get a list of the user's messages in the indicated mailbox on
#  the source host
#
sub getMsgList {

my $mailbox = shift;
my $msgs    = shift;
my $conn    = shift;
my $mode    = shift;
my $seen;
my $empty;
my $msgnum;
my $from;
my $flags;
my $msgid;

   @$msgs  = ();
   $mode = 'EXAMINE' unless $mode;
   sendCommand ($conn, "1 $mode \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ / 0 EXISTS/i ) { $empty=1; }
	if ( $response =~ /^1 OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		return 0;
	}
   }

   return 1 if $empty;

   my $start = 1;
   my $end   = '*';
   $start = $start_fetch if $start_fetch;
   $end   = $end_fetch   if $end_fetch;

   sendCommand ( $conn, "1 FETCH $start:$end (uid flags internaldate body[header.fields (From Date Message-Id)])");
   
   @response = ();
   while ( 1 ) {
	readResponse ( $conn );

	if ( $response =~ /^1 OK/i ) {
		last;
	} 
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;
   }

   $flags = '';
   for $i (0 .. $#response) {
	last if $response[$i] =~ /^1 OK FETCH complete/i;

        if ($response[$i] =~ /FLAGS/) {
           #  Get the list of flags
           $response[$i] =~ /FLAGS \(([^\)]*)/;
           $flags = $1;
           $flags =~ s/\\Recent//;
        }

        if ( $response[$i] =~ /INTERNALDATE/) {
           $response[$i] =~ /INTERNALDATE (.+) BODY/i;
           # $response[$i] =~ /INTERNALDATE "(.+)" BODY/;
           $date = $1;
           
           $date =~ /"(.+)"/;
           $date = $1;
           $date =~ s/"//g;
        }

        if ( $response[$i] =~ /^Message-Id: (.+)/i ) {
           $msgid = $1;
        }

        # if ( $response[$i] =~ /\* (.+) [^FETCH]/ ) {
        if ( $response[$i] =~ /\* (.+) FETCH/ ) {
           ($msgnum) = split(/\s+/, $1);
        }

        if ( $msgnum and $date and $msgid ) {
        # if ( $msgnum and $date ) {
	   push (@$msgs,"$msgnum|$date|$flags|$msgid");
           $msgnum = $date = $msgid = '';
        }
   }

   return 1;

}

#  getDatedMsgList
#
#  Get a list of the user's messages in a mailbox on
#  the host which were sent after the specified date
#
sub getDatedMsgList {

my $mailbox = shift;
my $cutoff_date = shift;
my $msgs    = shift;
my $conn    = shift;
my $oper    = shift;
my ($seen, $empty, @list,$msgid);

    #  Get a list of messages sent after the specified date

    Log("Searching for messages after $cutoff_date");

    @list  = ();
    @$msgs = ();

    sendCommand ($conn, "1 $oper \"$mailbox\"");
    while ( 1 ) {
        readResponse ($conn);
        if ( $response =~ / EXISTS/i) {
            $response =~ /\* ([^EXISTS]*)/;
            # Log("     There are $1 messages in $mailbox");
        } elsif ( $response =~ /^1 OK/i ) {
            last;
        } elsif ( $response =~ /^1 NO/i ) {
            Log ("unexpected SELECT response: $response");
            return 0;
        } elsif ( $response !~ /^\*/ ) {
            Log ("unexpected SELECT response: $response");
            return 0;
        }
    }

    my ($date,$ts) = split(/\s+/, $cutoff_date);

    #
    #  Get list of messages sent before the reference date
    #
    Log("Get messages sent after $date") if $debug;
    $nums = "";
    sendCommand ($conn, "1 SEARCH SINCE \"$date\"");
    while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^1 OK/i ) {
	    last;
	}
	elsif ( $response =~ /^\*\s+SEARCH/i ) {
	    ($nums) = ($response =~ /^\*\s+SEARCH\s+(.*)/i);
	}
	elsif ( $response !~ /^\*/ ) {
	    Log ("unexpected SEARCH response: $response");
	    return;
	}
    }
    Log("$nums") if $debug;
    if ( $nums eq "" ) {
	Log ("     $mailbox has no messages sent before $date") if $debug;
	return;
    }
    my @number = split(/\s+/, $nums);
    $n = $#number + 1;

    $nums =~ s/\s+/ /g;
    @msgList = ();
    @msgList = split(/ /, $nums);

    if ($#msgList == -1) {
	#  No msgs in this mailbox
	return 1;
    }

@$msgs  = ();
for $num (@msgList) {

     sendCommand ( $conn, "1 FETCH $num (uid flags internaldate body[header.fields (Message-Id Date)])");
     
     undef @response;
     while ( 1 ) {
	readResponse   ( $conn );
        Log("RESP1 $response");
	if   ( $response =~ /^1 OK/i ) {
		last;
	}   
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;
     }

     $flags = '';
     my $msgid;
     foreach $_ ( @response ) {
	last   if /^1 OK FETCH complete/i;
          if ( /FLAGS/ ) {
             #  Get the list of flags
             /FLAGS \(([^\)]*)/;
             $flags = $1;
             $flags =~ s/\\Recent//;
          }
   
          if ( /Message-Id:\s*(.+)/i ) {
             $msgid = $1;
          }

          if ( /INTERNALDATE/) {
             /INTERNALDATE (.+) BODY/i;
             $date = $1;
             $date =~ /"(.+)"/;
             $date = $1;
             $date =~ s/"//g;
             ####  next if check_cutoff_date( $date, $cutoff_date );
          }

          if ( /\* (.+) FETCH/ ) {
             ($msgnum) = split(/\s+/, $1);
          }

          if ( $msgnum and $date ) {
             push (@$msgs,"$msgnum|$date|$flags|$msgid");
             $msgnum=$msgid=$date=$flags='';
          }
      }
   }

   foreach $_ ( @$msgs ) {
      Log("getDated found $_") if $debug;
   }

   return 1;
}

sub mbxExists {

my $mbx  = shift;
my $conn = shift;
my $status = 1;

   #  Determine whether a mailbox exists
   sendCommand ($conn, "1 EXAMINE \"$mbx\"");
   while (1) {
        readResponse ($conn);
        last if $response =~ /^1 OK/i;
        if ( $response =~ /^1 NO|^1 BAD|^\* BYE/ ) {
           $status = 0;
           last; 
        }
   }

   return $status;
}

sub fetchMsg {

my $msgnum = shift;
my $message = shift;
my $mbx    = shift;
my $conn   = shift;

   Log("   Fetching msg $msgnum...") if $debug;

   $$message = '';
   sendCommand( $conn, "1 FETCH $msgnum (rfc822)");
   while (1) {
	readResponse ($conn);
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;

if ( $response eq '' ) {
        Log("RESP2 >$response<");
   resume();
   return 0;
}
	if ( $response =~ /^1 OK/i ) {
		$size = length($$message);
		last;
	} 
	elsif ($response =~ /message number out of range/i) {
		Log ("Error fetching uid $uid: out of range",2);
		$stat=0;
		last;
	}
	elsif ($response =~ /Bogus sequence in FETCH/i) {
		Log ("Error fetching uid $uid: Bogus sequence in FETCH",2);
		$stat=0;
		last;
	}
	elsif ( $response =~ /message could not be processed/i ) {
		Log("Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		push(@errors,"Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		$stat=0;
		last;
	}
	elsif 
	   ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{[0-9]+\}/i) {
		($len) = ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{([0-9]+)\}/i);
		$cc = 0;
		$$message = "";
		while ( $cc < $len ) {
			$n = 0;
			$n = read ($conn, $segment, $len - $cc);
			if ( $n == 0 ) {
				Log ("unable to read $len bytes");
                                resume();
				return 0;
			}
			$$message .= $segment;
			$cc += $n;
		}
	}
   }

   return 1;
}


sub usage {

   print STDOUT "usage:\n";
   print STDOUT " imapcopy -S sourceHost/sourceUser/sourcePassword [/CRAM-MD5]\n";
   print STDOUT "          -D destHost/destUser/destPassword [/CRAM-MD5]\n";
   print STDOUT "          -d debug\n";
   print STDOUT "          -I show IMAP protocol exchanges\n";
   print STDOUT "          -L logfile\n";
   print STDOUT "          -m mailbox list (eg \"Inbox, Drafts, Notes\". Default is all mailboxes)\n";
   print STDOUT "          -R include submailboxes when used with -m\n\n";
   print STDOUT "          -e exclude mailbox list\n";
   print STDOUT "          -r remove msgs from source mbx after copying\n";
   print STDOUT "          -p <mailbox> put copied mailboxes under a root mailbox\n";
   print STDOUT "          -A <mailbox> copy to local mailbox from scrmbx\n";
   print STDOUT "          -x <mbx delimiter [mbx prefix]>  source (eg, -x '. INBOX.'\n";
   print STDOUT "          -y <mbx delimiter [mbx prefix]>  destination\n";
   print STDOUT "          -i initialize mailbox (remove existing messages first\n";
   print STDOUT "          -M <file> mailbox map file. Maps src mbxs to dst mbxs. ";
   print STDOUT "Each line in the file should be 'src mbx:dst mbx'\n";
   print STDOUT "          -q quiet mode (still writes to the logfile)\n";
   print STDOUT "          -t <timeout in seconds>\n";
   print STDOUT "          -T copy custom flags (eg, \$Label1,\$MDNSent,etc)\n";
   print STDOUT "          -a <DD-MMM-YYYY> copy only messages after this date\n";
   print STDOUT "          -X <megabytes> Skip any message exceeding this size\n";
   print STDOUT "          -U update mode, don't copy messages that already exist\n";
   print STDOUT "          -B <msgnum>  Starting point for message fetch\n";
   print STDOUT "          -E <msgnum>  Ending point for message fetch\n";
   exit;

}

sub processArgs {

   if ( !getopts( "dS:D:L:m:hIp:M:rqx:y:e:Rt:Tia:X:vP:A:UB:E:" ) ) {
      usage();
   }
   if ( $opt_S =~ /\\/ ) {
      ($sourceHost, $sourceUser, $sourcePwd,$srcMethod) = split(/\\/, $opt_S);
   } else {
      ($sourceHost, $sourceUser, $sourcePwd,$srcMethod) = split(/\//, $opt_S);
   }
   if ( $opt_D =~ /\\/ ) {
      ($destHost, $destUser, $destPwd,$dstMethod)     = split(/\\/, $opt_D);
   } else {
      ($destHost, $destUser, $destPwd,$dstMethod)     = split(/\//, $opt_D);
   }

   $mbxList  = $opt_m;
   $logfile  = $opt_L;
   $root_mbx = $opt_p;
   $timeout  = $opt_t;
   $tags     = $opt_T;
   $debug    = 1 if $opt_d;
   $verbose  = 1 if $opt_v;
   $showIMAP = 1 if $opt_I;
   $submbxs  = 1 if $opt_R;
   $init_mbx = 1 if $opt_i;
   $quiet_mode  = 1 if $opt_q;
   $update   = 1 if $opt_U;
   $include_nosel_mbxs = 1 if $opt_s;
   $rem_src_msgs = 1 if $opt_r;
   $mbx_map_fn  = $opt_M;
   $excludeMbxs = $opt_e;
   $sent_after  = $opt_a;
   $max_size    = $opt_X;
   $public_mbxs = $opt_P;
   $archive_mbx = $opt_A;
   $start_fetch = $opt_B;
   $end_fetch   = $opt_E;
   $timeout = 300 unless $timeout;

   Log("Running in update mode") if $update;

   validate_date( $sent_after ) if $sent_after;
   usage() if $opt_h;

}

sub selectMbx {

my $mbx = shift;
my $conn = shift;

   #  Some IMAP clients such as Outlook and Netscape) do not automatically list
   #  all mailboxes.  The user must manually subscribe to them.  This routine
   #  does that for the user by marking the mailbox as 'subscribed'.

   sendCommand( $conn, "1 SUBSCRIBE \"$mbx\"");
   while ( 1 ) {
      readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         Log("Mailbox $mbx has been subscribed") if $debug;
         last;
      } elsif ( $response =~ /^1 NO|^1 BAD|\^* BYE/i ) {
         Log("Unexpected response to subscribe $mbx command: $response");
         last;
      }
   }

   #  Now select the mailbox
   sendCommand( $conn, "1 SELECT \"$mbx\"");
   while ( 1 ) {
      readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         last;
      } elsif ( $response =~ /^1 NO|^1 BAD|^\* BYE/i ) {
         Log("Unexpected response to SELECT $mbx command: $response");
         last;
      }
   }

}

sub namespace {

my $conn      = shift;
my $prefix    = shift;
my $delimiter = shift;
my $mbx_delim = shift;

   #  Query the server with NAMESPACE so we can determine its
   #  mailbox prefix (if any) and hierachy delimiter.

   if ( $mbx_delim ) {
      #  The user has supplied a mbx delimiter and optionally a prefix.
      Log("Using user-supplied mailbox hierarchy delimiter $mbx_delim");
      ($$delimiter,$$prefix) = split(/\s+/, $mbx_delim);
      return;
   }

   @response = ();
   sendCommand( $conn, "1 NAMESPACE");
   while ( 1 ) {
      readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         last;
      } elsif ( $response =~ /^1 NO|^1 BAD|^\* BYE/i ) {
         Log("Unexpected response to NAMESPACE command: $response");
         last;
      }
   }

   foreach $_ ( @response ) {
      if ( /NAMESPACE/i ) {
         my $i = index( $_, '((' );
         my $j = index( $_, '))' );
         my $val = substr($_,$i+2,$j-$i-3);
         ($val) = split(/\)/, $val);
         ($$prefix,$$delimiter) = split( / /, $val );
         $$prefix    =~ s/"//g;
         $$delimiter =~ s/"//g;
      
         #  Experimental
         if ( $public_mbxs ) {
            #  Figure out the public mailbox settings
            /\(\((.+)\)\)\s+\(\((.+)\s+\(\((.+)\)\)/;
            $public = $3;
            $public =~ /"(.+)"\s+"(.+)"/;
            $src_public_prefix = $1 if $conn eq $src;
            $src_public_delim  = $2 if $conn eq $src;
            $dst_public_prefix = $1 if $conn eq $dst;
            $dst_public_delim  = $2 if $conn eq $dst;
         }
         last;
      }
      last if /^1 NO|^1 BAD|^\* BYE/;
   }

   unless ( $$delimiter ) {
      #  NAMESPACE command is not supported by the server
      #  so we will have to figure it out another way.
      $delim = getDelimiter( $conn );
      $$delimiter = $delim;
      $$prefix = '';
   }

   if ( $debug ) {
      Log("prefix  >$$prefix<");
      Log("delim   >$$delimiter<");
   }
}

sub mailboxName {

my $srcmbx    = shift;
my $srcPrefix = shift;
my $srcDelim  = shift;
my $dstPrefix = shift;
my $dstDelim  = shift;
my $dstmbx;
my $substChar = '_';

   if ( $public_mbxs ) {
      my ($public_src,$public_dst) = split(/:/, $public_mbxs );
      #  If the mailbox starts with the public mailbox prefix then
      #  map it to the public mailbox destination prefix

      if ( $srcmbx =~ /^$public_src/ ) {
         Log("src: $srcmbx is a public mailbox") if $debug;
         $dstmbx = $srcmbx;
         $dstmbx =~ s/$public_src/$public_dst/;
         Log("dst: $dstmbx") if $debug;
         return $dstmbx;
      }
   }

   #  Change the mailbox name if the user has supplied mapping rules.

   if ( $mbx_map{"$srcmbx"} ) {
      $srcmbx = $mbx_map{"$srcmbx"} 
   }

   #  Adjust the mailbox name if the source and destination server
   #  have different mailbox prefixes or hierarchy delimiters.

   if ( ($srcmbx =~ /[$dstDelim]/) and ($dstDelim ne $srcDelim) ) {
      #  The mailbox name has a character that is used on the destination
      #  as a mailbox hierarchy delimiter.  We have to replace it.
      $srcmbx =~ s^[$dstDelim]^$substChar^g;
   }

   if ( $debug ) {
      Log("src mbx      $srcmbx");
      Log("src prefix   $srcPrefix");
      Log("src delim    $srcDelim");
      Log("dst prefix   $dstPrefix");
      Log("dst delim    $dstDelim");
   }

   $srcmbx =~ s/^$srcPrefix//;
   $srcmbx =~ s/\\$srcDelim/\//g;
 
   if ( ($srcPrefix eq $dstPrefix) and ($srcDelim eq $dstDelim) ) {
      #  No adjustments necessary
      # $dstmbx = $srcmbx;
      if ( lc( $srcmbx ) eq 'inbox' ) {
         $dstmbx = $srcmbx;
      } else {
         $dstmbx = $srcPrefix . $srcmbx;
      }
      if ( $root_mbx ) {
         #  Put folders under a 'root' folder on the dst
         $dstmbx =~ s/^$dstPrefix//;
         $dstDelim =~ s/\./\\./g;
         $dstmbx =~ s/^$dstDelim//;
         $dstmbx = $dstPrefix . $root_mbx . $dstDelim . $dstmbx;
         if ( uc($srcmbx) eq 'INBOX' ) {
            #  Special case for the INBOX
            $dstmbx =~ s/INBOX$//i;
            $dstmbx =~ s/$dstDelim$//;
         }
         $dstmbx =~ s/\\//g;
      }
      return $dstmbx;
   }

   $srcmbx =~ s#^$srcPrefix##;
   $dstmbx = $srcmbx;

   if ( $srcDelim ne $dstDelim ) {
       #  Need to substitute the dst's hierarchy delimiter for the src's one
       $srcDelim = '\\' . $srcDelim if $srcDelim eq '.';
       $dstDelim = "\\" . $dstDelim if $dstDelim eq '.';
       $dstmbx =~ s#$srcDelim#$dstDelim#g;
       $dstmbx =~ s/\\//g;
   }
   if ( $srcPrefix ne $dstPrefix ) {
       #  Replace the source prefix with the dest prefix
       $dstmbx =~ s#^$srcPrefix## if $srcPrefix;
       if ( $dstPrefix ) {
          $dstmbx = "$dstPrefix$dstmbx" unless uc($srcmbx) eq 'INBOX';
       }
       $dstDelim = "\\$dstDelim" if $dstDelim eq '.';
       $dstmbx =~ s#^$dstDelim##;
   } 
      
   if ( $root_mbx ) {
      #  Put folders under a 'root' folder on the dst
      $dstDelim =~ s/\./\\./g;
      $dstmbx =~ s/^$dstPrefix//;
      $dstmbx =~ s/^$dstDelim//;
      $dstmbx = $dstPrefix . $root_mbx . $dstDelim . $dstmbx;
      if ( uc($srcmbx) eq 'INBOX' ) {
         #  Special case for the INBOX
         $dstmbx =~ s/INBOX$//i;
         $dstmbx =~ s/$dstDelim$//;
      }
      $dstmbx =~ s/\\//g;
   }

   return $dstmbx;
}

sub flags {

my $flags = shift;
my @newflags;
my $newflags;

   #  Make sure the flags list contains standard 
   #  IMAP flags and optionally custom tags

   return unless $flags;

   $flags =~ s/\\Recent//i;
   foreach $_ ( split(/\s+/, $flags) ) {
      push( @newflags, $_ ) if substr($_,0,1) eq '\\';
      if ( $opt_T ) {
         #  Include user-defined flags
         push( @newflags, $_ ) if substr($_,0,1) eq '$';
      }
   }

   $newflags = join( ' ', @newflags );

   $newflags =~ s/\\Deleted//ig if $opt_r;
   $newflags =~ s/^\s+|\s+$//g;

   return $newflags;
}

sub map_mbx_names {

my $mbx_map = shift;
my $srcDelim = shift;
my $dstDelim = shift;

   #  The -M <file> argument causes imapcopy to read the
   #  contents of a file with mappings between source and
   #  destination mailbox names. This permits the user to
   #  to change the name of a mailbox when copying messages.
   #
   #  The lines in the file should be formatted as:
   #       <source mailbox name>: <destination mailbox name>
   #  For example:
   #       Drafts/2008/Save:  Draft_Messages/2008/Save
   #       Action Items: Inbox
   #
   #  Note that if the names contain non-ASCII characters such
   #  as accents or diacritical marks then the Perl module
   #  Unicode::IMAPUtf7 module must be installed.

   return unless $mbx_map_fn;

   unless ( open(MAP, "<$mbx_map_fn") ) {
      Log("Error opening mbx map file $mbx_map_fn: $!");
      exit;
   }
   $use_utf7 = 0;
   while( <MAP> ) {
      chomp;
      s/[\r\n]$//;   # In case we're on Windows
      s/^\s+//;
      next if /^#/;
      next unless $_;
      ($srcmbx,$dstmbx) = split(/\s*:\s*/, $_);

      #  Unless the mailbox name is entirely ASCII we'll have to use
      #  the Modified UTF-7 character set.
      $use_utf7 = 1 unless isAscii( $srcmbx );
      $use_utf7 = 1 unless isAscii( $dstmbx );

      $srcmbx =~ s/\//$srcDelim/g;
      $dstmbx =~ s/\//$dstDelim/g;

      $$mbx_map{"$srcmbx"} = $dstmbx;

   }
   close MAP;

   if ( $use_utf7 ) {
      eval 'use Unicode::IMAPUtf7';
      if ( $@ ) {
         Log("At least one mailbox map contains non-ASCII characters.  This means you");
         Log("have to install the Perl Unicode::IMAPUtf7 module in order to map mailbox ");
         Log("names between the source and destination servers.");
         print "At least one mailbox map contains non-ASCII characters.  This means you\n";
         print "have to install the Perl Unicode::IMAPUtf7 module in order to map mailbox\n";
         print "names between the source and destination servers.\n";
         exit;
      }
   }

   my %temp;
   foreach $srcmbx ( keys %$mbx_map ) {
      $dstmbx = $$mbx_map{"$srcmbx"};
      Log("Mapping src:$srcmbx to dst:$dstmbx");
      if ( $use_utf7 ){
         #  Encode the name in Modified UTF-7 charset
         $srcmbx = Unicode::IMAPUtf7::imap_utf7_encode( $srcmbx );
         $dstmbx = Unicode::IMAPUtf7::imap_utf7_encode( $dstmbx );
      }
      $temp{"$srcmbx"} = $dstmbx;
   }
   %$mbx_map = %temp;
   %temp = ();

}

sub isAscii {

my $str = shift;
my $ascii = 1;

   #  Determine whether a string contains non-ASCII characters

   my $test = $str;
   $test=~s/\P{IsASCII}/?/g;
   $ascii = 0 unless $test eq $str;

   return $ascii;

}

sub getDelimiter  {

my $conn = shift;
my $delimiter;

   #  Issue a 'LIST "" ""' command to find out what the
   #  mailbox hierarchy delimiter is.

   sendCommand ($conn, '1 LIST "" ""');
   @response = '';
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^1 OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		return 0;
	}
   }

   for $i (0 .. $#response) {
        $response[$i] =~ s/\s+/ /;
        if ( $response[$i] =~ /\* LIST \((.*)\) "(.*)" "(.*)"/i ) {
           $delimiter = $2;
        }
   }

   return $delimiter;
}

#  Reconnect to the servers after a timeout error.
#
sub reconnect {

my $checkpoint = shift;
my $conn = shift;

   Log("Attempting to reconnect");

   my ($mbx,$shost,$suser,$spwd,$dhost,$duser,$dpwd) = split(/\|/, $checkpoint);

   close $src;
   close $dst;

   connectToHost($shost,\$src);
   login($suser,$spwd,$shost,$src);

   connectToHost($dhost,\$dst);
   login($duser,$dpwd,$dhost,$dst);

   selectMbx( $mbx, $src );
   createMbx( $mbx, $dst );   # Just in case

}

#  Handle signals

sub signalHandler {

my $sig = shift;

   if ( $sig eq 'ALRM' ) {
      Log("Caught a SIG$sig signal, timeout error");
      $conn_timed_out = 1;
   } else {
      Log("Caught a SIG$sig signal, shutting down");
      exit;
   }
   Log("Resuming");
}

sub fixup_date {

my $date = shift;

   #  Make sure the hrs part of the date is 2 digits.  At least
   #  one IMAP server expects this.

   $$date =~ s/^\s+//;
   $$date =~ /(.+) (.+):(.+):(.+) (.+)/;
   my $hrs = $2;
   
   return if length( $hrs ) == 2;

   my $newhrs = '0' . $hrs if length( $hrs ) == 1;
   $$date =~ s/ $hrs/ $newhrs/;

}

sub init_mbx {

my $mbx  = shift;
my $conn = shift;
my @msgs;

   #  Remove all messages from a mailbox

   Log("Initializing mailbox $mbx");
   getMsgList( $mbx, \@msgs, $conn, 'SELECT' ); 
   my $msgcount = $#msgs + 1;
   Log("$mbx has $msgcount messages");

   return if $msgcount == 0;   #  No messages to delete

   foreach my $msgnum ( @msgs ) {
      ($msgnum) = split(/\|/, $msgnum);
      delete_msg( $msgnum, $conn );
   }
   expungeMbx( $mbx, $conn );

}

sub delete_msg_list {

my $msgnums = shift;
my $mbx     = shift;
my $conn    = shift;
my $rc;

   #  Mark a set of messages for deletion

   selectMbx( $mbx, $conn );

   foreach my $msgnum ( split(/\s+/, $msgnums ) ) {
      sendCommand ( $conn, "1 STORE $msgnum +FLAGS (\\Deleted)");
      while (1) {
         readResponse ($conn);
         if ( $response =~ /^1 OK/i ) {
  	    $rc = 1;
	    Log("      Marked msg number $msgnum for delete") if $debug;
	    last;
	 }

	 if ( $response =~ /^1 BAD|^1 NO/i ) {
	    Log("Error setting \Deleted flag for msg $msgnum: $response");
	    $rc = 0;
	    last;
	 }
      }
   }

   return $rc;

}

sub expungeMbx {

my $mbx   = shift;
my $conn  = shift;

   Log("Expunging mailbox $mbx");

   sendCommand ($conn, "1 SELECT \"$mbx\"");
   while (1) {
        readResponse ($conn);
        last if ( $response =~ /1 OK/i );
   }

   sendCommand ( $conn, "1 EXPUNGE");
   $expunged=0;
   while (1) {
        readResponse ($conn);
        $expunged++ if $response =~ /\* (.+) Expunge/i;
        last if $response =~ /^1 OK/;

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   Log("Error purging messages: $response");
	   last;
	}
   }

   $totalExpunged += $expunged;

   Log("$expunged messages expunged");

}

sub cram_md5 {

my $challenge = shift;
my $user      = shift;
my $password  = shift;

eval 'use Digest::HMAC_MD5 qw(hmac_md5_hex)'; 
use MIME::Base64 qw(decode_base64 encode_base64); 

   # Adapated from script by Paul Makepeace <http://paulm.com>, 2002-10-12 
   # Takes user, key, and base-64 encoded challenge and returns base-64 
   # encoded CRAM. See, 
   # IMAP/POP AUTHorize Extension for Simple Challenge/Response: 
   # RFC 2195 http://www.faqs.org/rfcs/rfc2195.html 
   # SMTP Service Extension for Authentication: 
   # RFC 2554 http://www.faqs.org/rfcs/rfc2554.html 
   # Args: tim tanstaaftanstaaf PDE4OTYuNjk3MTcwOTUyQHBvc3RvZmZpY2UucmVzdG9uLm1jaS5uZXQ+ 
   # should yield: dGltIGI5MTNhNjAyYzdlZGE3YTQ5NWI0ZTZlNzMzNGQzODkw 

   my $challenge_data = decode_base64($challenge); 
   my $hmac_digest = hmac_md5_hex($challenge_data, $password); 
   my $response = encode_base64("$user $hmac_digest"); 
   chomp $response;

   if ( $debug ) {
      Log("Challenge: $challenge_data");
      Log("HMAC digest: $hmac_digest"); 
      Log("CRAM Base64: $response");
   }

   return $response;
}

sub validate_date {

my $date = shift;
my $invalid;

   #  Make sure the "after" date is in DD-MMM-YYYY format

   my ($day,$month,$year) = split(/-/, $date);
   $invalid = 1 unless ( $day > 0 and $day < 32 );
   $invalid = 1 unless $month =~ /Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec/i;
   $invalid = 1 unless $year > 1900 and $year < 2999;
   if ( $invalid ) {
      Log("The 'Sent after' date $date must be in DD-MMM-YYYY format");
      exit;
   }
}

sub commafy {

my $number = shift;

   $_ = $$number;
   1 while s/^([-+]?\d+)(\d{3})/$1,$2/;

   $$number = $_;

}

sub delete_msg {

my $msgnum = shift;
my $conn   = shift;
my $rc;

   sendCommand ( $conn, "1 STORE $msgnum +FLAGS (\\Deleted)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
           $rc = 1;
           Log("      Marked msg number $msgnum for delete") if $debug;
           last;
        }

        if ( $response =~ /^1 BAD|^1 NO/i ) {
           Log("Error setting \Deleted flag for msg $msgnum: $response");
           $rc = 0;
           last;
        }
   }

   return $rc;



}


sub resume {

   #  Disconnect, re-connect, and log back in.

   Log("Fatal error, lost connection to either the source or destination");
   # Log("checkpoint $checkpoint");
   Log("LAST $LAST");
   my ($mbx,$msgnum) = split(/\|/, $LAST);
Log("mbx $mbx");
   Log("Disconnect from the source and destination servers");

   close $src;
   close $dst;
 
   Log("Sleeping 15 seconds before reconnecting");
   sleep 15;

   Log("Reconnect to source server and log back in");
   connectToHost($sourceHost, \$src)   or exit;
   login($sourceUser,$sourcePwd, $sourceHost, $src, $srcMethod) or exit;
   selectMbx( $mbx, $src );

   Log("Reconnect to destination server and log back in");
   connectToHost( $destHost, \$dst ) or exit;
   login( $destUser,$destPwd, $destHost, $dst, $dstMethod ) or exit;
   Log("Resuming");

   #  Just in case we were creating a mailbox when the connection
   #  was lost check and recreate it if necessary

Log("does $mbx exist?");
   createMbx( $mbx, $dst ) unless mbxExists( $mbx, $dst );

   return;

}


#  getMsgIdList
#
#  Get a list of the user's messages in a mailbox
#
sub getMsgIdList {

my $mailbox = shift;
my $msgids  = shift;
my $conn    = shift;
my $empty;
my $msgnum;
my $from;
my $msgid;

   %$msgids  = ();
   sendCommand ($conn, "1 EXAMINE \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ / 0 EXISTS/i ) { $empty=1; }
	if ( $response =~ /^1 OK/i ) {
		# print STDERR "response $response\n";
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		# print STDERR "Error: $response\n";
		return 0;
	}
   }

   if ( $empty ) {
      return;
   }

   Log("Fetch the header info") if $debug;

   sendCommand ( $conn, "1 FETCH 1:* (body[header.fields (Message-Id)])");
   undef @response;
   while ( 1 ) {
	readResponse ( $conn );
	return if $conn_timed_out;
	if ( $response =~ /^1 OK/i ) {
	   last;
	} elsif ( $response =~ /could not be processed/i ) {
           Log("Error:  response from server: $response");
           return;
        } elsif ( $response =~ /^1 NO|^1 BAD/i ) {
           return;
        }
   }

   $flags = '';
   for $i (0 .. $#response) {
       $_ = $response[$i];

       last if /OK FETCH complete/;

       if ($response[$i] =~ /Message-ID: (.+)/i) {
          $$msgids{"$1"} = 1;
       }
   }

}

sub encode_ampersand {

my $mbx = shift;

   #  The IMAP RFC requires mailbox names with '&' be 
   #  encoded as '&-'

   #  The problem with this routine is a mailbox name may be
   #  encoded in Mod UTF7 which uses the '&' character for its
   #  own purposes, eg r&AOk-pertoire_XXX.  We have to leave it
   #  alone.  Anyway, this code was inserted because of an IMAP
   #  server which did not do its job so the usefulness of this
   #  conversion is limited.  

   if ( $$mbx =~ /\&/ ) {
      if ( $$mbx !~ /\&-/ ) {
         #  Need to encode the '&' as '&-'
         $$mbx =~ s/\&/\&-/g;
         Log("Encoded $$mbx");
      }
   }

}

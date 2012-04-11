# IMAP::Utils - common parts of imaputils scripts
#use strict;
#use warnings;

package IMAP::Utils;
require Exporter;
@ISA = qw(Exporter);
@EXPORT= qw(Log openLog);

sub openLog {
   #  Open the logFile
   #
   $logfile = shift;
   if ( $logfile ) {
      if ( !open(LOG, ">> $logfile")) {
         print STDOUT "Can't open $logfile: $!\n";
         exit;
      }
      select(LOG); $| = 1;
   }
}

#
#  Log
#
#  This subroutine formats and writes a log message to STDOUT
#

sub Log {

my $str = shift;

   ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
   if ($year < 99) { $yr = 2000; }
   else { $yr = 1900; }
   $line = sprintf ("%.2d-%.2d-%d.%.2d:%.2d:%.2d %s %s\n",
             $mon + 1, $mday, $year + $yr, $hour, $min, $sec,$$,$str);
   print LOG "$line";
   print STDOUT "$str\n";

}

1;

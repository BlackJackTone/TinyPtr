#!/usr/bin/perl -w
#
# stackcollapse-perf.pl	collapse perf samples into single lines.
#
# Parses a list of multiline stacks generated by "perf script", and
# outputs a semicolon separated stack followed by a space and a count.
# If memory addresses (+0xd) are present, they are stripped, and resulting
# identical stacks are colased with their counts summed.
#
# USAGE: ./stackcollapse-perf.pl [options] infile > outfile
#
# Run "./stackcollapse-perf.pl -h" to list options.
#
# Example input:
#
#  swapper     0 [000] 158665.570607: cpu-clock:
#         ffffffff8103ce3b native_safe_halt ([kernel.kallsyms])
#         ffffffff8101c6a3 default_idle ([kernel.kallsyms])
#         ffffffff81013236 cpu_idle ([kernel.kallsyms])
#         ffffffff815bf03e rest_init ([kernel.kallsyms])
#         ffffffff81aebbfe start_kernel ([kernel.kallsyms].init.text)
#  [...]
#
# Example output:
#
#  swapper;start_kernel;rest_init;cpu_idle;default_idle;native_safe_halt 1
#
# Input may be created and processed using:
#
#  perf record -a -g -F 997 sleep 60
#  perf script | ./stackcollapse-perf.pl > out.stacks-folded
#
# The output of "perf script" should include stack traces. If these are missing
# for you, try manually selecting the perf script output; eg:
#
#  perf script -f comm,pid,tid,cpu,time,event,ip,sym,dso,trace | ...
#
# This is also required for the --pid or --tid options, so that the output has
# both the PID and TID.
#
# Copyright 2012 Joyent, Inc.  All rights reserved.
# Copyright 2012 Brendan Gregg.  All rights reserved.
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at docs/cddl1.txt or
# http://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at docs/cddl1.txt.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
# 02-Mar-2012	Brendan Gregg	Created this.
# 02-Jul-2014	   "	  "	Added process name to stacks.

use strict;
use Getopt::Long;

my %collapsed;

sub remember_stack {
	my ($stack, $count) = @_;
	$collapsed{$stack} += $count;
}
my $annotate_kernel = 0; # put an annotation on kernel function
my $annotate_jit = 0;   # put an annotation on jit symbols
my $annotate_all = 0;   # enale all annotations
my $include_pname = 1;	# include process names in stacks
my $include_pid = 0;	# include process ID with process name
my $include_tid = 0;	# include process & thread ID with process name
my $include_addrs = 0;	# include raw address where a symbol can't be found
my $tidy_java = 1;	# condense Java signatures
my $tidy_generic = 1;	# clean up function names a little
my $target_pname;	# target process name from perf invocation
my $event_filter = "";    # event type filter, defaults to first encountered event
my $event_defaulted = 0;  # whether we defaulted to an event (none provided)
my $event_warning = 0;	  # if we printed a warning for the event

my $show_inline = 0;
my $show_context = 0;

my $srcline_in_input = 0; # if there are extra lines with source location (perf script -F+srcline)
GetOptions('inline' => \$show_inline,
           'context' => \$show_context,
           'srcline' => \$srcline_in_input,
           'pid' => \$include_pid,
           'kernel' => \$annotate_kernel,
           'jit' => \$annotate_jit,
           'all' => \$annotate_all,
           'tid' => \$include_tid,
           'addrs' => \$include_addrs,
           'event-filter=s' => \$event_filter)
or die <<USAGE_END;
USAGE: $0 [options] infile > outfile\n
	--pid		# include PID with process names [1]
	--tid		# include TID and PID with process names [1]
	--inline	# un-inline using addr2line
	--all		# all annotations (--kernel --jit)
	--kernel	# annotate kernel functions with a _[k]
	--jit		# annotate jit functions with a _[j]
	--context	# adds source context to --inline
	--srcline	# parses output of 'perf script -F+srcline' and adds source context
	--addrs		# include raw addresses where symbols can't be found
	--event-filter=EVENT	# event name filter\n
[1] perf script must emit both PID and TIDs for these to work; eg, Linux < 4.1:
	perf script -f comm,pid,tid,cpu,time,event,ip,sym,dso,trace
    for Linux >= 4.1:
	perf script -F comm,pid,tid,cpu,time,event,ip,sym,dso,trace
    If you save this output add --header on Linux >= 3.14 to include perf info.
USAGE_END

if ($annotate_all) {
	$annotate_kernel = $annotate_jit = 1;
}

my %inlineCache;

my %nmCache;

sub inlineCacheAdd {
	my ($pc, $mod, $result) = @_;
   if (defined($inlineCache{$pc})) {
      $inlineCache{$pc}{$mod} = $result;
   } else {
      $inlineCache{$pc} = {$mod => $result};
   }
}

# for the --inline option
sub inline {
	my ($pc, $rawfunc, $mod) = @_;

	return $inlineCache{$pc}{$mod} if defined($inlineCache{$pc}{$mod});

	# capture addr2line output
	my $a2l_output = `addr2line -a $pc -e $mod -i -f -s -C`;

	# remove first line
	$a2l_output =~ s/^(.*\n){1}//;

	if ($a2l_output =~ /\?\?\n\?\?:0/) {
		# if addr2line fails and rawfunc is func+offset, then fall back to it
		if ($rawfunc =~ /^(.+)\+0x([0-9a-f]+)$/) {
			my $func = $1;
			my $addr = hex $2;

			$nmCache{$mod}=`nm $mod` unless defined $nmCache{$mod};

			if ($nmCache{$mod} =~ /^([0-9a-f]+) . \Q$func\E$/m) {
			   my $base = hex $1;
				my $newPc = sprintf "0x%x", $base+$addr;
				my $result = inline($newPc, '', $mod);
				inlineCacheAdd($pc, $mod, $result);
				return $result;
			}
		}
	}

	my @fullfunc;
	my $one_item = "";
	for (split /^/, $a2l_output) {
		chomp $_;

		# remove discriminator info if exists
		$_ =~ s/ \(discriminator \S+\)//;

		if ($one_item eq "") {
			$one_item = $_;
		} else {
			if ($show_context == 1) {
				unshift @fullfunc, $one_item . ":$_";
			} else {
				unshift @fullfunc, $one_item;
			}
			$one_item = "";
		}
	}

	my $result = join ";" , @fullfunc;

	inlineCacheAdd($pc, $mod, $result);

	return $result;
}

my @stack;
my $pname;
my $m_pid;
my $m_tid;
my $m_period;

#
# Main loop
#
while (defined($_ = <>)) {

	# find the name of the process launched by perf, by stepping backwards
	# over the args to find the first non-option (no dash):
	if (/^# cmdline/) {
		my @args = split ' ', $_;
		foreach my $arg (reverse @args) {
			if ($arg !~ /^-/) {
				$target_pname = $arg;
				$target_pname =~ s:.*/::;  # strip pathname
				last;
			}
		}
	}

	# skip remaining comments
	next if m/^#/;
	chomp;

	# end of stack. save cached data.
	if (m/^$/) {
		# ignore filtered samples
		next if not $pname;

		if ($include_pname) {
			if (defined $pname) {
				unshift @stack, $pname;
			} else {
				unshift @stack, "";
			}
		}
		remember_stack(join(";", @stack), $m_period) if @stack;
		undef @stack;
		undef $pname;
		next;
	}

	#
	# event record start
	#
	if (/^(\S.+?)\s+(\d+)\/*(\d+)*\s+/) {
		# default "perf script" output has TID but not PID
		# eg, "java 25607 4794564.109216: 1 cycles:"
		# eg, "java 12688 [002] 6544038.708352: 235 cpu-clock:"
		# eg, "V8 WorkerThread 25607 4794564.109216: 104345 cycles:"
		# eg, "java 24636/25607 [000] 4794564.109216: 1 cycles:"
		# eg, "java 12688/12764 6544038.708352: 10309278 cpu-clock:"
		# eg, "V8 WorkerThread 24636/25607 [000] 94564.109216: 100 cycles:"
		# other combinations possible
		my ($comm, $pid, $tid, $period) = ($1, $2, $3, "");
		if (not $tid) {
			$tid = $pid;
			$pid = "?";
		}

		if (/:\s*(\d+)*\s+(\S+):\s*$/) {
			$period = $1;
			my $event = $2;

			if ($event_filter eq "") {
				# By default only show events of the first encountered
				# event type. Merging together different types, such as
				# instructions and cycles, produces misleading results.
				$event_filter = $event;
				$event_defaulted = 1;
			} elsif ($event ne $event_filter) {
				if ($event_defaulted and $event_warning == 0) {
					# only print this warning if necessary:
					# when we defaulted and there was
					# multiple event types.
					print STDERR "Filtering for events of type: $event\n";
					$event_warning = 1;
				}
				next;
			}
		}

		if (not $period) {
			$period = 1
		}
		($m_pid, $m_tid, $m_period) = ($pid, $tid, $period);

		if ($include_tid) {
			$pname = "$comm-$m_pid/$m_tid";
		} elsif ($include_pid) {
			$pname = "$comm-$m_pid";
		} else {
			$pname = "$comm";
		}
		$pname =~ tr/ /_/;

	#
	# stack line
	#
	} elsif (/^\s*(\w+)\s*(.+) \((.*)\)/) {
		# ignore filtered samples
		next if not $pname;

		my ($pc, $rawfunc, $mod) = ($1, $2, $3);

		if ($show_inline == 1 && $mod !~ m/(perf-\d+.map|kernel\.|\[[^\]]+\])/) {
			my $inlineRes = inline($pc, $rawfunc, $mod);
			# - empty result this happens e.g., when $mod does not exist or is a path to a compressed kernel module
			#   if this happens, the user will see error message from addr2line written to stderr
			# - if addr2line results in "??" , then it's much more sane to fall back than produce a '??' in graph
			if($inlineRes ne "" and $inlineRes ne "??" and $inlineRes ne "??:??:0" ) {
				unshift @stack, $inlineRes;
				next;
			}
		}

		# Linux 4.8 included symbol offsets in perf script output by default, eg:
		# 7fffb84c9afc cpu_startup_entry+0x800047c022ec ([kernel.kallsyms])
		# strip these off:
		$rawfunc =~ s/\+0x[\da-f]+$//;

		next if $rawfunc =~ /^\(/;		# skip process names

		my $is_unknown=0;
		my @inline;
		for (split /\->/, $rawfunc) {
			my $func = $_;

			if ($func eq "[unknown]") {
				if ($mod ne "[unknown]") { # use module name instead, if known
					$func = $mod;
					$func =~ s/.*\///;
				} else {
					$func = "unknown";
					$is_unknown=1;
				}

				if ($include_addrs) {
					$func = "\[$func \<$pc\>\]";
				} else {
					$func = "\[$func\]";
				}
			}

			if ($tidy_generic) {
				$func =~ s/;/:/g;
				if ($func !~ m/\.\(.*\)\./) {
					# This doesn't look like a Go method name (such as
					# "net/http.(*Client).Do"), so everything after the first open
					# paren (that is not part of an "(anonymous namespace)") is
					# just noise.
					$func =~ s/\((?!anonymous namespace\)).*//;
				}
				# now tidy this horrible thing:
				# 13a80b608e0a RegExp:[&<>\"\'] (/tmp/perf-7539.map)
				$func =~ tr/"\'//d;
				# fall through to $tidy_java
			}

			if ($tidy_java and $pname =~ m/^java/) {
				# along with $tidy_generic, converts the following:
				#	Lorg/mozilla/javascript/ContextFactory;.call(Lorg/mozilla/javascript/ContextAction;)Ljava/lang/Object;
				#	Lorg/mozilla/javascript/ContextFactory;.call(Lorg/mozilla/javascript/C
				#	Lorg/mozilla/javascript/MemberBox;.<init>(Ljava/lang/reflect/Method;)V
				# into:
				#	org/mozilla/javascript/ContextFactory:.call
				#	org/mozilla/javascript/ContextFactory:.call
				#	org/mozilla/javascript/MemberBox:.init
				$func =~ s/^L// if $func =~ m:/:;
			}

			#
			# Annotations
			#
			# detect inlined from the @inline array
			# detect kernel from the module name; eg, frames to parse include:
			#          ffffffff8103ce3b native_safe_halt ([kernel.kallsyms]) 
			#          8c3453 tcp_sendmsg (/lib/modules/4.3.0-rc1-virtual/build/vmlinux)
			#          7d8 ipv4_conntrack_local+0x7f8f80b8 ([nf_conntrack_ipv4])
			# detect jit from the module name; eg:
			#          7f722d142778 Ljava/io/PrintStream;::print (/tmp/perf-19982.map)
			if (scalar(@inline) > 0) {
				$func .= "_[i]" unless $func =~ m/\_\[i\]/;	# inlined
			} elsif ($annotate_kernel == 1 && $mod =~ m/(^\[|vmlinux$)/ && $mod !~ /unknown/) {
				$func .= "_[k]";	# kernel
			} elsif ($annotate_jit == 1 && $mod =~ m:/tmp/perf-\d+\.map:) {
				$func .= "_[j]" unless $func =~ m/\_\[j\]/;	# jitted
			}

			#
			# Source lines
			#
			#
			# Sample outputs:
			#   | a.out 35081 252436.005167:     667783 cycles:
			#   |                   408ebb some_method_name+0x8b (/full/path/to/a.out)
			#   |   uniform_int_dist.h:300
			#   |                   4069f5 main+0x935 (/full/path/to/a.out)
			#   |   file.cpp:137
			#   |             7f6d2148eb25 __libc_start_main+0xd5 (/lib64/libc-2.33.so)
			#   |   libc-2.33.so[27b25]
			#
			#   | a.out 35081 252435.738165:     306459 cycles:
			#   |             7f6d213c2750 [unknown] (/usr/lib64/libkmod.so.2.3.6)
			#   |   libkmod.so.2.3.6[6750]
			#
			#   | a.out 35081 252435.738373:     315813 cycles:
			#   |             7f6d215ca51b __strlen_avx2+0x4b (/lib64/libc-2.33.so)
			#   |   libc-2.33.so[16351b]
			#   |             7ffc71ee9580 [unknown] ([unknown])			
			#   |
			#
			#   | a.out 35081 252435.718940:     247984 cycles:
			#   |         ffffffff814f9302 up_write+0x32 ([kernel.kallsyms])
			#   |   [kernel.kallsyms][ffffffff814f9302]
			if($srcline_in_input and not $is_unknown){
				$_ = <>;
				chomp;
				s/\[.*?\]//g;
				s/^\s*//g;
				s/\s*$//g;
				$func.=':'.$_ unless $_ eq "";
			}

			push @inline, $func;
		}

		unshift @stack, @inline;
	} else {
		warn "Unrecognized line: $_";
	}
}

foreach my $k (sort { $a cmp $b } keys %collapsed) {
	print "$k $collapsed{$k}\n";
}
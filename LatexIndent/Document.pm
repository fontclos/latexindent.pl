package LatexIndent::Document;
use strict;
use warnings;
use Data::Dumper;
use Data::UUID;

# gain access to subroutines in the following modules
use LatexIndent::Logfile qw/logger output_logfile processSwitches get_switches/;
use LatexIndent::GetYamlSettings qw/masterYamlSettings readSettings/;
use LatexIndent::Verbatim qw/put_verbatim_back_in find_verbatim_environments find_noindent_block/;
use LatexIndent::BackUpFileProcedure qw/create_back_up_file/;

sub new{
    # Create new objects, with optional key/value pairs
    # passed as initializers.
    #
    # See Programming Perl, pg 319
    my $invocant = shift;
    my $class = ref($invocant) || $invocant;
    my $self = {@_};
    bless ($self,$class);
    return $self;
}


sub remove_leading_space{
    my $self = shift;
    $self->logger("Removing leading space from entire document (verbatim/noindentblock already accounted for)",'heading');
    ${$self}{body} =~ s/
                        (   
                            ^           # beginning of the line
                            \h*         # with 0 or more horizontal spaces
                        )?              # possibly
                        //mxg;
    return;
}

sub operate_on_file{
    my $self = shift;
    $self->masterYamlSettings;
    # file extension check
    $self->create_back_up_file;
    $self->find_noindent_block;
    $self->remove_trailing_comments;
    $self->find_verbatim_environments;
    # find filecontents environments
    # find preamble
    $self->remove_leading_space;
    # remove trailing spaces
    # find alignment environments
    $self->process_body_of_text;
    # process alignment environments
    $self->put_verbatim_back_in;
    $self->put_trailing_comments_back_in;
    $self->output_indented_text;
    $self->output_logfile;
    return
}

sub output_indented_text{
    my $self = shift;

    # output to screen, unless silent mode
    print ${$self}{body} unless ${%{$self}{switches}}{silentMode};

    $self->logger("Output routine",'heading');

    # if -overwrite is active then output to original fileName
    if(${%{$self}{switches}}{overwrite}) {
        $self->logger("Overwriting file ${$self}{fileName}");
        open(OUTPUTFILE,">",${$self}{fileName});
        print OUTPUTFILE ${$self}{body};
        close(OUTPUTFILE);
    } elsif(${%{$self}{switches}}{outputToFile}) {
        $self->logger("Outputting to file ${%{$self}{switches}}{outputToFile}");
        open(OUTPUTFILE,">",${%{$self}{switches}}{outputToFile});
        print OUTPUTFILE ${$self}{body};
        close(OUTPUTFILE);
    } else {
        $self->logger("Not outputting to file; see -w and -o switches for more options.");
    }
    return;
}

sub process_body_of_text{
    my $self = shift;

    # search for environments
    $self->logger('looking for ENVIRONMENTS','heading');
    $self->find_environments;

    # if there are no verbatim children, return
    if(%{$self}{children}){
        $self->logger("Objects have been found.",'heading');
    } else {
        $self->logger("No objects found.",'heading');
        return;
    }

    # logfile information
    $self->logger(Dumper(\%{$self}),'ttrace');
    $self->logger("Operating on: $self",'heading');
    $self->logger("Number of children:",'heading');
    $self->logger(scalar keys %{%{$self}{children}});
    $self->logger('Pre-processed body:','heading');
    $self->logger(${$self}{body});
    $self->logger("Indenting children objects:",'heading');

    # loop through document children hash
    while( (scalar keys %{%{$self}{children}})>0 ){
          while( my ($key,$child)= each %{%{$self}{children}}){
            if(${$self}{body} =~ m/
                        (   
                            ^           # beginning of the line
                            \h*         # with 0 or more horizontal spaces
                        )?              # possibly
                                        #
                        (.*?)?          # any other character
                        ${$child}{id}   # the ID
                        (\h*)?          # possibly followed by horizontal space
                        (\R*)?          # then line breaks
                        /mx){
                my $indentation = $1?$1:q();
                my $IDFirstNonWhiteSpaceCharacter = $2?0:1;
                my $IDFollowedImmediatelyByLineBreak = $4?1:0;

                # log file info
                $self->logger("Indentation info",'heading');
                $self->logger("object name: ${$child}{name}");
                $self->logger("current indentation: '$indentation'");
                $self->logger("looking up indentation scheme for ${$child}{name}");

                # line break checks for begin and end
                if(${$child}{BeginStartsOnOwnLine} and !$IDFirstNonWhiteSpaceCharacter){
                    $self->logger("Adding a linebreak at the beginning of ${$child}{begin} (see BeginStartsOnOwnLine)");
                    ${$child}{begin} = "\n".${$child}{begin};
                    ${$child}{begin} =~ s/^(\h*)?/$indentation/mg;  # add indentation
                }

                if(${$child}{EndFinishesWithLineBreak} and !$IDFollowedImmediatelyByLineBreak){
                    $self->logger("Adding a linebreak at the end of ${$child}{end} (see EndFinishesWithLineBreak)");
                    ${$child}{end} =~ s/\h*$/\n/;
                    ${$child}{linebreaksAtEnd}{end} = 1;
                }

                # perform indentation
                $child->indent($indentation);
                $self->logger(Dumper(\%{$child}),'ttrace');

                # replace ids with body
                ${$self}{body} =~ s/${$child}{id}/${$child}{begin}${$child}{body}${$child}{end}/;

                # log file info
                $self->logger('Body now looks like:','heading.trace');
                $self->logger(${$self}{body},'trace');

                # delete the hash so it won't be operated upon again
                delete ${$self}{children}{${$child}{id}};
                $self->logger("deleted key");
              }
            }
    }

    # logfile info
    $self->logger("Number of children:",'heading');
    $self->logger(scalar keys %{%{$self}{children}});
    $self->logger('Post-processed body:','trace');
    $self->logger(${$self}{body},'trace');
    return;
}

sub find_environments{
    my $self = shift;
    while( ${$self}{body} =~ m/
                (
                    \\begin\{
                            (.*?)       # environment name captured into $2
                           \}           # \begin{<something>} statement
                            (\R*)?      # possible line breaks (into $3)
                )                       # begin statement captured into $1
                (
                    (?:                 # cluster-only (), don't capture 
                        (?!             # don't include \begin in the body
                            (?:\\begin) # cluster-only (), don't capture
                        ).              # any character, but not \\begin
                    )*?                 # non-greedy
                            (\R*)?      # possible line breaks (into $5)
                )                       # environment body captured into $4
                (
                    \\end\{\2\}         # \end{<something>} statement
                    (\h*)?              # possibly followed by horizontal space
                )                       # captured into $6
                /sx){

      # create a new Environment object
      my $env = LatexIndent::Environment->new(begin=>$1,
                                              name=>$2,
                                              body=>$4,
                                              end=>$6,
                                              linebreaksAtEnd=>{
                                                begin=> ($3)?1:0,
                                                body=> ($5)?1:0,
                                                end=> ($7)?1:0,
                                              },
                                            );

      # get settings for this object
      $env->get_indentation_settings_for_this_object;

      $self->logger(Dumper(\%{$env}),'trace');

      # give unique id
      $env->create_unique_id;

      # store children in special hash
      ${$self}{children}{${$env}{id}}=$env;

      # log file output
      $self->logger("environment found: $2");

      # remove the environment block, and replace with unique ID
      ${$self}{body} =~ s/
                (\\begin\{(.*?)\}   # the \begin{<something>} statement
                (\R*)?)             # possible line breaks
                (((?!(\\begin)).)*?)
                (\\end\{\2\}(\h*)?)       # the \end{<something>} statement
                /${$env}{id}/sx;

      $self->logger("replaced with ID: ${$env}{id}");
    } 
    return;
  }

sub create_unique_id{
    my $self = shift;

    # generate a unique ID (http://stackoverflow.com/questions/18628244/how-we-can-create-a-unique-id-in-perl)
    my $uuid1 = Data::UUID->new->create_str();

    # allocate id to the object
    ${$self}{id} = $uuid1;
    return;
}

sub remove_trailing_comments{
    my $self = shift;
    $self->logger("Storing trailing comments",'heading');
    my $commentCounter = 0;
    ${$self}{body} =~ s/
                            (?<!\\)  # not preceeded by a \
                            %        # % 
                            (
                                \h*? # followed by possible horizontal space
                                .*?  # and anything else
                            )
                            $        # up to the end of a line
                        /   
                            # increment comment counter and store comment
                            $commentCounter++;
                            ${${$self}{trailingcomments}}{"latexindenttrailingcomment$commentCounter"}= $1;

                            # replace comment with dummy text
                            "% latexindenttrailingcomment".$commentCounter;
                       /xsmeg;
    if(%{$self}{trailingcomments}){
        $self->logger("Trailing comments stored in:",'trace');
        $self->logger(Dumper(\%{%{$self}{trailingcomments}}),'trace');
    } else {
        $self->logger("No trailing comments found",'trace');
    }
    return;
}

sub put_trailing_comments_back_in{
    my $self = shift;
    return unless(%{$self}{trailingcomments});

    $self->logger("Returning trailing comments to body",'heading');
    while( my ($trailingcommentID,$trailingcommentValue)= each %{%{$self}{trailingcomments}}){
        ${$self}{body} =~ s/%\h$trailingcommentID/%$trailingcommentValue/;
        $self->logger("replace $trailingcommentID with $trailingcommentValue",'trace');
    }
    return;
}

1;

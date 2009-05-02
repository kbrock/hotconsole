require 'lib/eval_thread' # for EvalThread and standard output redirection

require 'hotcocoa'
framework 'webkit'
include HotCocoa

# TODO:
# - stdin (should not be very hard but it's used only very rarely so very low priority)
# - do not perform_action if the code typed is not finished (needs a basic lexer)
# - maybe always displays puts/writes before the prompt?
$terminals = []

class Terminal
  #user event (via should_close)
  def alertDidEnd alert, returnCode: return_code, contextInfo: context_info
    return if return_code == NSAlertSecondButtonReturn # do nothing if the use presses cancel
    
    # in all cases, first ask the thread to end nicely if possible
    @eval_thread.end_thread
    
    @window.close
    
    @eval_thread.kill_running_threads if return_code == NSAlertFirstButtonReturn # kill the running code if asked
  end
  
  #user event
  def should_close?
    # we can always close directly is nothing is running
    return true if command_line and not @eval_thread.children_threads_running?
    
    alert = NSAlert.alloc.init
    alert.messageText = "Some code is still running in this console.\nDo you really want to close it?"
    alert.alertStyle = NSCriticalAlertStyle
    alert.addButtonWithTitle("Close and kill")
    alert.addButtonWithTitle("Cancel")
    alert.addButtonWithTitle("Close and let run")
    alert.beginSheetModalForWindow @window, modalDelegate: self, didEndSelector: "alertDidEnd:returnCode:contextInfo:", contextInfo: nil
    false
  end
  FULL={:expand => [:window,:height]}
  def start
    @line_num = 1
    @history = [ ]
    @pos_in_history = 0

    @eval_thread = EvalThread.new(self)

    frame = [300, 300, 600, 400]
    w = NSApp.mainWindow
    if w
      frame[0] = w.frame.origin.x + 20
      frame[1] = w.frame.origin.y - 20
    end
    #@prompt = text_view(:frame => [0,0,500,100],:layout => {:expand => [:width,:height], :start => false})
    #?@prompt.editingDelegate = self # for ? (will only work for nstextview vs nstextfield)
    
    #TODO: need to set font to monaco
    #TODO: need scroll bars (putting into scroll_view caused issues)

    #TODO: need scrollbars. but this caused the text_field/view to become too small
    #full_prompt= scroll_view(:frame => [0,0,600,100], :layout => {:expand => [:width,:height], :start => true})
    #full_prompt.document_view = @prompt
    #full_prompt=@prompt

    @window = window(:frame => frame, :title => "HotConsole") do |win|
      win << split_view(:frame => [0,0,600,400],:horizontal => true, :layout => FULL) do |sview|
        #set a default size. (better way to do this?
        sview << @web_view = web_view(:frame => [0,0,200,300],:layout => FULL) do |wv|
          wv.editingDelegate = self # for webView:doCommandBySelector:
          wv.frameLoadDelegate = self # for webView:didFinishLoadForFrame:
          wv.url=local_page_path
        end
        sview << @prompt = text_field(:frame => [0,0,500,100],:layout => FULL,
          :on_action => Proc.new { |p|
            perform_action(p.to_s)
            p.text='' #@prompt.text=''
          }) do |tf|
            tf.setFont(font(:name=>'Monaco', :size => 16))
        end
      end
      win.contentView.margin = 5

      win.should_close? { self.should_close? }
      win.will_close {
        $terminals.delete(self)
        @window_closed = true
      }
      win.did_become_main {
        # we want order in $terminals to be
        # last used terminal to most recent used
        $terminals.delete(self)
        $terminals << self
      }
    end

    class << @window
      attr_accessor :terminal
    end
    @window.terminal = self
    @window_closed = false
    give_prompt_focus

    $terminals << self
  end
  
  def local_page_path
    bundle=NSBundle.mainBundle
    raise "no mainBundle" unless bundle
    fullPath=NSBundle.pathForResource("index", :ofType => "html", :inDirectory => bundle.bundlePath)
    raise "no index file in mainBundle (Contents/Resources)" unless fullPath
    "file://#{fullPath}"
  end
  
  def content_body
    document.getElementById('content')
  end

  #user clicks clear from the menu
  def clear
    content_body.innerHTML = ''
  end

  # return the HTML document of the main frame
  def document
    @web_view.mainFrame.DOMDocument
  end
  
  def display_history(change)
    if change < 0 && @pos_in_history > 0
      @pos_in_history -= 1
    elsif change > 0 && @pos_in_history < @history.length
      @pos_in_history += 1
    end
    
    @prompt.text = @history[@pos_in_history] || ''
     
    # if we do not move the caret to the beginning,
    # we lose the focus if the command line is emptied
    give_prompt_focus
  end
  
  # # callback called when a command by selector is run on the WebView
  # def webView webView, doCommandBySelector: command
  #   if command == 'insertNewline:' # Return
  #     perform_action
  #   elsif command == 'moveBackward:' # Alt+Up Arrow
  #     display_history(-1)
  #   elsif command == 'moveForward:' # Alt+Down Arrow
  #     display_history(+1)
  #   # moveToBeginningOfParagraph and moveToEndOfParagraph are also sent by Alt+Up/Down
  #   # but we must ignore them because they move the cursor
  #   elsif command != 'moveToBeginningOfParagraph:' and command != 'moveToEndOfParagraph:'
  #     return false
  #   end
  #   true
  # end

  def new_command_div
    @current_command_div=document.createElement('div')
    @current_command_div.setAttribute('class', value:'hentry')
    content_body.appendChild(@current_command_div)
  end

  def current_command_div
    #content_body
     @current_command_div
  end

  def write_command(cmd)
    h3=document.createElement('h3')
    h3.setAttribute('class', value:'hentry-title')
    h3.innerText=cmd
    #div#updated for run date
    #div#entry-content for results
    write_element(h3)
  end

  # simply writes (appends) a DOM element to the current command output
  def write_element(element)
    current_command_div.appendChild(element)
  end
  
  def write(obj)
    if obj.respond_to?(:to_str)
      text = obj
    else
      text = obj.to_s
    end

    if @window_closed
      # if the window was closed while code that printed text was still running,
      # the text is displayed on the most recently used terminal if there is one,
      # or the standard error output if no terminal was found
      target = $terminals.last || STDERR
      target.write(text)
    else
      # if the window is still opened, just put the text
      # in a DOM div element and writes it on the WebView
      span = document.createElement('p')
      span.innerText = text
      write_element(span)
    end
  end
  
  # puts is just a write of the text followed by a carriage return and that returns nil
  def puts(obj)
    if obj.respond_to?(:to_ary)
      obj.each { |elem| puts elem }
    else
      # we do not call just write because of encoding/string problems
      # and because Ruby itself does it in two calls to write
      write obj
      #write "\n"
      #kb: note, since the write is putting it into a p, ignore advice and just do a single write
    end
  end

  def scroll_to_bottom
    document.body.scrollTop = document.body.scrollHeight
    #refresh web view (after scroll)
    @web_view.setNeedsDisplay true
  end
  
  def begin_edition
    #TODO disable text field
    @prompt.setEditable(false)
    @prompt.setBackgroundColor(color(:rgb => 0x333333))
  end

  def end_edition
    @prompt.setEditable(true)
    @prompt.setBackgroundColor(color(:name => :white))
  end

  def give_prompt_focus
    @window.makeFirstResponder @prompt
  end

  def write_prompt
    end_edition
    #clear the prompt
    give_prompt_focus
    scroll_to_bottom
  end

  # executes the code written on the prompt when the user validates it with return
  def perform_action(command)
    command||=@prompt.to_s
    current_line_number = @line_num

    if command.strip.empty?
      write_prompt
      return
    end

    new_command_div
    write_command command #put it into the top view

    @line_num += command.count("\n")+1
    
    @history.push(command)
    @pos_in_history = @history.length

    begin_edition
    # the code is sent to an other thread that will do the evaluation
    @eval_thread.send_command(current_line_number, command)
    # the user must not be able to modify the prompt until the command ends
    # (when back_from_eval is called)
  end

  # back_from_eval is called when the evaluation thread has finished its evaluation of the given code
  # text is either the representation of the value returned by the code executed, or the backtrace of an exception
  def back_from_eval(text)
    # if the window was closed while code was still executing,
    # we can just ignore the call because there is no need
    # to print the result and a new prompt
    return if @window_closed
    write text
    write_prompt
  end
  def back_from_eval_result(value)
    return if @window_closed
    write "=> #{value.inspect}\n" #inspect not necessary
    write_prompt
  end
end

class Application
  def start
    application :name => "HotConsole" do |app|
      app.delegate = self
      start_terminal
    end
  end

  #menu options

  def on_new(sender)
    start_terminal
  end

  def on_close(sender)
    w = NSApp.mainWindow
    if w
      w.performClose self
    else
      NSBeep()
    end
  end
  
  def on_run_command(sender)
    tell_main_win(:perform_action)
  end
  
  def on_previous_command(sender)
    tell_main_win(:display_history,-1)
  end

  def on_next_command(sender)
    tell_main_win(:display_history,+1)
  end
  
  def on_clear(sender)
    tell_main_win(:clear)
  end

  private

  def start_terminal
    Terminal.new.start
  end
  
  def tell_main_win(*args)
    w = NSApp.mainWindow
    if w and w.respond_to?(:terminal)
      w.terminal.send(*args)
    else
      NSBeep()
    end
  end
end

Application.new.start

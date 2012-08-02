%%%-------------------------------------------------------------------
%%% @author Paul Peter Flis <pawel@flycode.pl>
%%% @copyright (C) 2012, Green Elephant Labs
%%% @doc
%%% kha_builder module
%%% @end
%%% Created : 31 Jul 2012 by Paul Peter Flis <pawel@flycode.pl>
%%%-------------------------------------------------------------------
-module(kha_builder).

-include("kha.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([add_to_queue/1,
         add_to_queue/2,
         process/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([build_timeout/3]).

-define(SERVER, ?MODULE).

-record(state, {busy = false :: 'false' | {pid(), term()},
                queue}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

add_to_queue(#build{project = Project, id = Id} = _Build) ->
    add_to_queue(Project, Id).
add_to_queue(ProjectId, BuildId) ->
    gen_server:call(?SERVER, {add_to_queue, ProjectId, BuildId}).

process() ->
    gen_server:cast(?SERVER, process).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{queue = queue:new()}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call({add_to_queue, ProjectId, BuildId}, _From,
            #state{busy = Busy, queue = Queue} = S) ->

    NewQueue = queue:in({ProjectId, BuildId}, Queue),
    NewState = S#state{queue = NewQueue},
    case Busy of
        false -> kha_builder:process();
        _ -> do_nothing
    end,
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(process, #state{queue = Queue} = S) ->
    case queue:out(Queue) of
        {empty, _} ->
            {noreply, S#state{busy = false}};
        {{value, Job}, NewQueue} ->
            Pid = proc_lib:spawn(fun() -> do_process(Job) end),
            erlang:monitor(process, Pid),
            {noreply, S#state{busy = {Pid, Job}, queue = NewQueue}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN', _, process, Pid, NormalOrTimeout}, #state{busy = {Pid, _}} = State) when NormalOrTimeout == normal;
                                                                                              NormalOrTimeout == timeout ->
    kha_builder:process(),
    {noreply, State#state{busy = false}};

handle_info({'DOWN', _, process, Pid, _Reason}, #state{busy = {Pid, Job}} = State) ->
    {ProjectId, BuildId} = Job,
    {ok, Build0} = kha_build:get(ProjectId, BuildId),
    kha_build:update(Build0#build{status = failed}),
    kha_builder:process(),
    {noreply, State#state{busy = false}};

handle_info(_Info, State) ->
    {stop, {unknown_info, _Info}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

build_timeout(Pid, ProjectId, BuildId) ->
    {ok, Build0} = kha_build:get(ProjectId, BuildId),
    Build = Build0#build{status = timeout},
    kha_build:update(Build),
    exit(Pid, timeout).

do_process({ProjectId, BuildId}) ->
    {ok, P} = kha_project:get(ProjectId),
    {ok, Build0} = kha_build:get(ProjectId, BuildId),
    Build = Build0#build{status = building},
    kha_build:update(Build),
    kha_hooks:run(on_building, ProjectId, BuildId),
    Local = kha_utils:convert(P#project.local, str),
    Remote = kha_utils:convert(P#project.remote, str),
    Branch = kha_utils:convert(Build#build.branch, str),
    Revision = kha_utils:convert(Build#build.revision, str),

    {ok, Ref} = timer:apply_after(timer:minutes(1), ?MODULE, build_timeout, [self(), ProjectId, BuildId]),

    case filelib:is_dir(Local) of
        true -> ok;
        false ->
            ok = kha_git:clone(Remote, Local)
    end,

    Steps = [ {"git clone and checkout",
               fun() ->
                       case Revision of
                           undefined -> ok = kha_git:checkout(Local, Branch);
                           X -> ok = kha_git:checkout(Local, X)
                       end,

                       io_lib:format("git: Successfully checked out \"~s\" to \"~s\"~n", [Branch, Local])
               end} |
              [ {C,
                 fun() ->
                         kha_utils:sh(C, [{cd, Local}])
                 end} || C <- P#project.build ] ],

    BF = fun({Cmd, F}, B) ->
                 try
                     B2 = B#build{output = [io_lib:format("$ ~s~n", [Cmd]) | B#build.output]},
                     kha_build:update(B2),
                     D = F(),
                     B3 = B#build{output = [D | B2#build.output]},
                     kha_build:update(B3),
                     B3
                 catch
                     throw:{exec_error, {_, ExitCode, Reason}} ->
                         Be = B#build{output = [Reason | B#build.output],
                                      stop = now(),
                                      exit = ExitCode,
                                      status = failed},
                         throw({error, Be})
                 end
         end,
    Build2 = try
                 B2 = lists:foldl(BF, Build, Steps),
                 B2#build{status = success,
                          stop = now(),
                          exit = 0}
             catch
                 throw:{error, Bb} ->
                     Bb
             end,
    catch timer:cancel(Ref),
    kha_build:update(Build2),
    case Build2#build.status of
        success -> kha_hooks:run(on_success,   ProjectId, BuildId);
        failed  -> kha_hooks:run(on_failed, ProjectId, BuildId);
        timeout -> kha_hooks:run(on_failed, ProjectId, BuildId)
    end,
    Build2.

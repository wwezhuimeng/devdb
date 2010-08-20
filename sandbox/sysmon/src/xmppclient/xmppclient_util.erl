-module(xmppclient_util).

-include("erl_logger.hrl").


-define(RET_SUCCESS, ok).
-define(RET_FAILED, error).

-export([init/0,
         register_user/2, register_user/5,
	 login/2, login/5,
	 send_string/2,
	 send_message/3, send_message/4]).

init() ->
    application:start(exmpp).

register_user(Username, Password) ->
    register_user(Username, Password, 
	          sysmon:get_config(ejabberd_vhost, "91guoguo.com"), 
	          sysmon:get_config(ejabberd_ip, "127.0.0.1"), 
	          sysmon:get_config(ejabberd_port, 5222)).

register_user(Username, Password, VHost, Server, Port) ->
    MySession = exmpp_session:start(),
    MyJID = exmpp_jid:make(Username, VHost, random),
    exmpp_session:auth_basic_digest(MySession, MyJID, Password),
    {ok, _StreamId} = exmpp_session:connect_TCP(MySession, Server, Port),
    Ret = case exmpp_session:register_account(MySession, Password) of
	      ok ->
	          ?DEBUG("user: ~p register success", [Username]),
		  ?RET_SUCCESS;
	      Err ->
	          ?DEBUG("user: ~p register failed due to ~p", [Username, Err]),
		  ?RET_FAILED
          end,
    exmpp_session:stop(MySession),
    Ret.

login(Username, Password) ->
    login(Username, Password, 
	  sysmon:get_config(ejabberd_vhost, "91guoguo.com"),
	  sysmon:get_config(ejabberd_ip, "127.0.0.1"), 
	  sysmon:get_config(ejabberd_port, 5222)).

%% 成功返回Session; 失败返回undefined
login(Username, Password, VHost, Server, Port) ->
    MySession = exmpp_session:start(),
    MyJID = exmpp_jid:make(Username, VHost, random),
    exmpp_session:auth_basic_digest(MySession, MyJID, Password),
    {ok, _StreamId} = exmpp_session:connect_TCP(MySession, Server, Port),
    try exmpp_session:login(MySession) of
	_Any ->
	    Packet = exmpp_presence:set_status(exmpp_presence:available(), "ejabberdclient first presence"),
	    exmpp_session:send_packet(MySession, Packet),
	    ?DEBUG("user: ~p login success ~n", [Username]),
	    MySession
    catch
	throw:{auth_error, 'not-authorized'} ->
	    ?DEBUG("user: ~p can't login to the server ~n", [Username]),
            undefined
    end.


send_string(Session, String) ->
    [DataXml] = exmpp_xml:parse_document(String),
    ?DEBUG("[session#~p] send xml#~s~n", [Session, String]),
    exmpp_session:send_packet(Session, DataXml).


send_message(Session, User, Text) ->
    VHost = xmpptools_config:get_vhost(),
    send_message(Session, User, VHost, Text).
send_message(Session, User, VHost, Text) ->
    Jid = User ++ "@" ++ VHost,
    Data = io_lib:format(
           "<message to='~s' type='chat' xml:lang='en'>" ++
             "<body>~s</body>" ++
           "</message>", [Jid, Text]),
    send_string(Session, Data).
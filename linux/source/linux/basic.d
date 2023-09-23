/++
Linux

LinuxのAPIの呼び出しについてまとめます。

概要
2023年現在の公式ドキュメントには記載がありませんが、`core.sys.linux`パッケージにはLinuxの関数宣言・構造体定義が存在し、
`import core.sys.linux.io_uring;` のように`import`を行うことで各関数を利用できます。

`core.sys.linux`パッケージはLinux環境でのみ利用できるため、
利用する場合は `version (linux) { } else { }` といった形で`version`によるプラットフォームの明記を行うことをお勧めします。$(BR)
以下の例ではWindows等の環境でもビルドできるようにするためversionで囲って表記しています。

See_Also:
    必要な関数・構造体が利用できるかは、DMDのソースコードを確認する必要があります。$(BR)
    $(LINK https://github.com/dlang/dmd/tree/master/druntime/src/core/sys/linux)

Source: $(LINK_TO_SRC posix/source/linux/_basic.d)
+/
module linux.basic;


/++
LinuxのAPIを直接利用したechoサーバー・クライアントの例です。
+/
unittest
{
    version (linux)
    {
        // 利用するLinuxのモジュールをimportする
        import core.sys.linux.unistd;
        import core.sys.linux.fcntl;
        import core.sys.linux.epoll;
        import core.stdc.errno;
        import core.sys.linux.sys.socket;
        import core.sys.linux.netinet.in_;

        import std.algorithm : map;
        import std.container : Array;
        import std.exception : enforce, errnoEnforce, ErrnoException;
        import std.range : cycle, take, array;
        import std.typecons : Nullable, nullable;

        // ソケットをノンブロッキングにする関数
        void toNonBlock(int fd)
        {
            immutable flags = fcntl(fd, F_GETFL, 0);
            errnoEnforce(fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1);
        }

        // 成功またはIO待ちでなければエラーにする関数
        // IO待ち発生時は結果がisNullになる
        Nullable!T ioEnforce(
            T, string file = __FILE__, ulong line = __LINE__)(T result)
        {
            if (result != -1)
            {
                return nullable(result);
            }

            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                // EAGAIN・EWOULDBLOCKはクリア
                errno = 0;
                return typeof(return).init;
            }

            throw new ErrnoException(null, file, line);
        }

        // IO結果
        struct IOResult
        {
            // 送受信バイト数
            ssize_t n;

            // 接続先がcloseされたか
            bool isClosed;
        }

        // ノンブロッキング送信関数
        IOResult nonBlockingSend(int fd, const(void)[] data)
        {
            // dataをすべて送信し切るか、接続先がshutdownされるまで送信実行
            IOResult result;
            while (result.n < data.length && !result.isClosed)
            {
                immutable rest = cast(uint)(data.length - result.n);
                immutable r = ioEnforce(send(fd, &data[result.n], rest, 0));
                if (r.isNull)
                {
                    // IO待ちが発生したので中断
                    break;
                }

                // 送信バイト数を加算。0バイト送信時は接続先にshutdownされている
                result.n += r.get;
                result.isClosed = r.get == 0;
            }
            return result;
        }

        // ノンブロッキング受信関数
        IOResult nonBlockingReceive(int fd, void[] buffer)
        {
            // bufferにすべて受信し切るか、接続先がshutdownされるまで受信実行
            IOResult result;
            while (result.n < buffer.length && !result.isClosed)
            {
                immutable rest = cast(uint)(buffer.length - result.n);
                immutable r = ioEnforce(recv(fd, &buffer[result.n], rest, 0));
                if (r.isNull)
                {
                    // IO待ちが発生したので中断
                    break;
                }

                // 受信バイト数を加算。0バイト受信時は接続先にshutdownされている
                result.n += r.get;
                result.isClosed = r.get == 0;
            }
            return result;
        }

        // サーバー側listen用ソケットを生成する
        immutable listenerSocket = socket(AF_INET, SOCK_STREAM, 0);
        errnoEnforce(listenerSocket >= 0);
        scope(exit) close(listenerSocket);
        toNonBlock(listenerSocket);

        // ローカルホストのアドレスにbindする
        sockaddr_in listenAddress = {
            sin_family: AF_INET,
            sin_addr: {
                s_addr: htonl(INADDR_LOOPBACK),
            },
            // 未使用ポートを自動で割り当てる
            sin_port: 0,
        };
        errnoEnforce(bind(
            listenerSocket,
            cast(const(sockaddr)*) &listenAddress,
            cast(socklen_t) listenAddress.sizeof) == 0);

        // bindされたアドレスを調べる
        listenAddress = listenAddress.init;
        socklen_t addressLength = cast(socklen_t) listenAddress.sizeof;
        errnoEnforce(getsockname(
            listenerSocket, cast(sockaddr*) &listenAddress, &addressLength) == 0);

        // listen開始
        errnoEnforce(listen(listenerSocket, 1) == 0);

        // クライアントソケットを生成する
        immutable clientSocket = socket(AF_INET, SOCK_STREAM, 0);
        errnoEnforce(clientSocket >= 0);
        scope(exit) close(clientSocket);
        toNonBlock(clientSocket);

        // サーバーにconnectする
        immutable connectResult = connect(
            clientSocket,
            cast(const(sockaddr)*) &listenAddress,
            cast(socklen_t) listenAddress.sizeof);
        errnoEnforce(connectResult == 0 || errno == EINPROGRESS);

        // EINPROGRESSをクリア
        errno = 0;

        // 送受信対象のデータ。1000バイトの適当なデータを生成
        const(ubyte)[] sendPacket = (cast(ubyte[])[1, 2, 3, 4])
            .cycle.take(1000).array;
        ptrdiff_t clientSendPos;

        // サーバー側送受信バッファ
        Array!ubyte serverBuffer;
        ptrdiff_t serverSendPos;

        // クライアント側送受信バッファ
        Array!ubyte clientBuffer;

        // サーバー側のクライアントソケット
        int acceptedSocket = -1;

        // クライアント側送信処理
        void clientSend()
        {
            immutable result = nonBlockingSend(
                clientSocket, sendPacket[clientSendPos .. $]);
            clientSendPos += result.n;

            // 送信中にはcloseされない想定
            enforce(!result.isClosed, "server closed");
        }

        // クライアント側受信処理
        IOResult clientReceive()
        {
            ubyte[16] buffer;
            immutable result = nonBlockingReceive(clientSocket, buffer[]);
            clientBuffer.insertBack(buffer[0 .. result.n]);
            return result;
        }

        // サーバー側送信処理
        void serverSend()
        {
            immutable result = nonBlockingSend(
                acceptedSocket, serverBuffer.data[serverSendPos .. $]);
            serverSendPos += result.n;

            // 送信中にはcloseされない想定
            enforce(!result.isClosed, "client closed");
        }

        // サーバー側受信処理
        IOResult serverReceive()
        {
            ubyte[16] buffer;
            immutable result = nonBlockingReceive(acceptedSocket, buffer[]);
            serverBuffer.insertBack(buffer[0 .. result.n]);
            return result;
        }

        // epollインスタンス生成
        immutable epollInstance = epoll_create1(0);
        errnoEnforce(epollInstance >= 0);
        scope(exit) close(epollInstance);

        // リスナーソケットをepollインスタンスに登録
        epoll_event listenerEvent = {
            events: EPOLLIN,
            data: { fd: listenerSocket }
        };
        errnoEnforce(epoll_ctl(
            epollInstance, EPOLL_CTL_ADD, listenerSocket, &listenerEvent) == 0);

        // クライアントソケットをepollインスタンスに登録
        epoll_event clientEvent = {
            events: EPOLLIN | EPOLLOUT | EPOLLRDHUP,
            data: { fd: clientSocket }
        };
        errnoEnforce(epoll_ctl(
            epollInstance, EPOLL_CTL_ADD, clientSocket, &clientEvent) == 0);

        // クライアント・サーバーどちらも切断されるまで送受信実行
        epoll_event[3] events;
        epoll_event acceptedEvent;
        for (bool clientClosed = false, serverClosed = false;
                !clientClosed || !serverClosed ;) {

            // epoll_waitで待機。タイムアウト時はエラー
            errnoEnforce(epoll_wait(epollInstance, &events[0], events.length, 1000) > 0);

            // 発生した各イベントを処理する
            foreach (ref const e; events)
            {
                // エラーがあったら終了
                enforce(!(e.events & EPOLLERR), "EPOLLERR");

                // リスナーソケットの場合
                if (e.data.fd == listenerSocket)
                {
                    // 接続要求があった場合、まだaccept前ならacceptする
                    if ((e.events & EPOLLIN) && acceptedSocket == -1)
                    {
                        immutable accepted = ioEnforce(accept(listenerSocket, null, null));
                        if (!accepted.isNull)
                        {
                            acceptedSocket = accepted.get;
                            toNonBlock(acceptedSocket);
                            acceptedEvent.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP;
                            acceptedEvent.data.fd = acceptedSocket;
                            errnoEnforce(epoll_ctl(
                                epollInstance, EPOLL_CTL_ADD, acceptedSocket, &acceptedEvent) == 0);
                        }
                    }
                }

                // クライアントソケットの場合
                if (e.data.fd == clientSocket)
                {
                    // 書き込み可能の場合
                    if (e.events & EPOLLOUT)
                    {
                        // 送信データが残っていれば送受信
                        if (clientSendPos < sendPacket.length)
                        {
                            clientSend();
                            clientReceive();
                        }
                        else
                        {
                            // 残データがなければ送信シャットダウン。以降はデータ受信のみ行う。
                            errnoEnforce(shutdown(clientSocket, SHUT_WR) == 0);
                            clientEvent.events = EPOLLIN | EPOLLRDHUP;
                            clientEvent.data.fd = clientSocket;
                            errnoEnforce(epoll_ctl(
                                epollInstance, EPOLL_CTL_MOD, clientSocket, &clientEvent) == 0);
                        }
                    }

                    // 読み込み可能の場合、受信実行
                    if (e.events & EPOLLIN)
                    {
                        serverClosed = clientReceive().isClosed;
                    }

                    // クライアントソケット切断時。想定外の切断はエラー
                    if (e.events & EPOLLRDHUP)
                    {
                        enforce(serverClosed, "unexpected server EPOLLRDHUP");
                    }
                }

                // サーバー側のクライアントソケットの場合
                if (acceptedSocket != -1 && e.data.fd == acceptedSocket)
                {
                    // 書き込み可能の場合
                    if (e.events & EPOLLOUT)
                    {
                        // 送信データが残っていれば送信
                        if (serverSendPos < serverBuffer.length)
                        {
                            serverSend();
                        }
                        else if(clientClosed)
                        {
                            // 残データが無く、クライアントも送信完了していればシャットダウン
                            // 以降はデータ受信のみ行う
                            errnoEnforce(shutdown(acceptedSocket, SHUT_WR) == 0);
                            acceptedEvent.events = EPOLLIN | EPOLLRDHUP;
                            acceptedEvent.data.fd = acceptedSocket;
                            errnoEnforce(epoll_ctl(
                                epollInstance, EPOLL_CTL_MOD, acceptedSocket, &acceptedEvent) == 0);
                        }
                    }

                    // 読み込み可能の場合、受信実行
                    if (e.events & EPOLLIN)
                    {
                        clientClosed = serverReceive().isClosed;

                        // 受信に応じてecho開始
                        serverSend();
                    }
                }
            }
        }

        // 最終的な送受信結果が正しいかチェック
        assert(sendPacket == clientBuffer.data);
    }
}

version (linux)
{
    // システムコール呼び出し関数。druntimeに宣言が無いので追加
    extern(C) long syscall(long sysno, ...) @system nothrow @nogc;
}

/++
LinuxのAPIを直接利用したechoサーバー・クライアントの例です。
+/
unittest
{
    version (linux)
    {
        // 利用するLinuxのモジュールをimportする
        import core.sys.linux.unistd;
        import core.sys.linux.fcntl;
        import core.sys.linux.io_uring;
        import core.stdc.errno;
        import core.sys.linux.sys.socket;
        import core.sys.linux.netinet.in_;
        import core.sys.posix.sys.mman;
        import core.sys.linux.sys.mman : MAP_POPULATE; // Linuxのほうにしか定義が無い

        import std.exception : errnoEnforce, ErrnoException;
        import std.algorithm : max;

        // io_uringのシステムコールのコード
        version (Alpha)
        {
            // alpha環境だけ値が異なる
            enum __NR_io_uring_setup = 535;
            enum __NR_io_uring_enter = 536;
            enum __NR_io_uring_register = 537;
        }
        else
        {
            enum __NR_io_uring_setup = 425;
            enum __NR_io_uring_enter = 426;
            enum __NR_io_uring_register = 427;
        }

        // io_uring関連のシステムコールを呼び出す関数を定義する。
        // 将来的にはcore.sys.linuxに含まれるはず……。

        int io_uring_register(int fd, uint opcode, void* arg, uint nr_args)
        @system nothrow @nogc
        {
            return cast(int) syscall(__NR_io_uring_register, fd, opcode, arg, nr_args);
        }

        int io_uring_setup(uint entries, io_uring_params* p)
        @system nothrow @nogc
        {
            return cast(int) syscall(__NR_io_uring_setup, entries, p);
        }

        int io_uring_enter(int fd, uint to_submit, uint min_complete, uint flags)
        @system nothrow @nogc
        {
            return cast(int) syscall(__NR_io_uring_enter, fd, to_submit, min_complete, flags, null, 0);
        }

        // io_uringキューのエントリー数(深さ)
        enum URING_ENTRIES = 1;

        // デフォルトのパラメーターでio_uring生成
        io_uring_params params;
        immutable uringDescriptor = io_uring_setup(URING_ENTRIES, &params);
        if (uringDescriptor < 0)
        {
            throw new ErrnoException("error: io_uring_setup", uringDescriptor);   
        }
        scope(exit) close(uringDescriptor);

        // セットアップ結果のパラメーターから各キューサイズを計算する。
        size_t submitQueueSize = params.sq_off.array + params.sq_entries * uint.sizeof;
        size_t completionQueueSize = params.cq_off.cqes + params.cq_entries * io_uring_cqe.sizeof;

        // SINGLE_MMAPに対応していれば単一のmmapで送信キュー・完了キューをマップできるので、
        // サイズを同じにする。
        if (params.features & IORING_FEAT_SINGLE_MMAP)
        {
            immutable maxSize = max(submitQueueSize, completionQueueSize);
            submitQueueSize = maxSize;
            completionQueueSize = maxSize;
        }

        // メモリマップ実行
        auto submitQueuePointer = mmap(
            null,
            submitQueueSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_POPULATE,
            uringDescriptor,
            IORING_OFF_SQ_RING);
        errnoEnforce(submitQueuePointer != MAP_FAILED);
        scope(exit) munmap(submitQueuePointer, submitQueueSize);
    }
}

#!/bin/sh
# 本机验证 DNS 报文检查，不发送网络请求。
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/ProbeTest.java" <<'JAVA'
import java.util.Arrays;
public class ProbeTest {
    public static void main(String[] args) {
        byte[] query = new byte[17];
        query[1] = 42;
        query[5] = 1;
        query[14] = 1;
        query[16] = 1;
        byte[] answer = Arrays.copyOf(query, 33);
        answer[2] = (byte) 0x81;
        answer[7] = 1;
        answer[17] = (byte) 0xC0;
        answer[18] = 12;
        answer[20] = 1;
        answer[22] = 1;
        answer[28] = 4;
        answer[29] = 1;
        check(FlowDeckProbe.validResponse(answer, answer.length, 42, query));
        check(!FlowDeckProbe.validResponse(answer, answer.length - 1, 42, query));
        check(!FlowDeckProbe.validResponse(answer, answer.length, 43, query));
        answer[3] = 3;
        check(!FlowDeckProbe.validResponse(answer, answer.length, 42, query));
        answer[3] = 0;
        answer[14] = 28;
        check(!FlowDeckProbe.validResponse(answer, answer.length, 42, query));
        answer[14] = 1;
        answer[18] = 127;
        check(!FlowDeckProbe.validResponse(answer, answer.length, 42, query));
        System.out.println("PASS 6 DNS packet validation cases");
    }
    static void check(boolean result) {
        if (!result) { throw new AssertionError(); }
    }
}
JAVA
javac --release 8 -d "$work" "$source_dir/FlowDeckProbe.java" "$work/ProbeTest.java"
java -cp "$work" ProbeTest

import java.nio.file.Files;
import java.nio.file.Paths;
import org.objectweb.asm.*;

/** Host build tool only. Preserve release methods; wrap only the FIFO sender. */
public final class GateReleaseClass implements Opcodes {
    static final String OWNER = "de/audi/app/terminalmode/smartphone/androidauto2/nav/AndroidAutoClusterIntegration";
    static final String GATE = "de/audi/app/terminalmode/smartphone/androidauto2/nav/Mh2pVideoGate";
    public static void main(String[] args) throws Exception {
        ClassReader reader = new ClassReader(Files.readAllBytes(Paths.get(args[0])));
        if (!OWNER.equals(reader.getClassName())) throw new IllegalArgumentException("Wrong class");
        ClassWriter writer = new ClassWriter(reader, 0);
        final int[] count = { 0 };
        reader.accept(new ClassVisitor(ASM9, writer) {
            public MethodVisitor visitMethod(int access, String name, String desc, String sig, String[] exceptions) {
                if (name.equals("sendMirrorCommandUngated")) throw new IllegalArgumentException("Already patched");
                if (name.equals("sendMirrorCommand") && desc.equals("(Ljava/lang/String;)V")) {
                    if (access != ACC_PRIVATE) throw new IllegalArgumentException("Unexpected sender access");
                    count[0]++;
                    return super.visitMethod(access, "sendMirrorCommandUngated", desc, sig, exceptions);
                }
                return super.visitMethod(access, name, desc, sig, exceptions);
            }
            public void visitEnd() {
                if (count[0] != 1) throw new IllegalArgumentException("Expected one sender");
                MethodVisitor m = super.visitMethod(ACC_PRIVATE, "sendMirrorCommand", "(Ljava/lang/String;)V", null, null);
                m.visitCode();
                m.visitVarInsn(ALOAD, 0);
                m.visitVarInsn(ALOAD, 1);
                m.visitMethodInsn(INVOKESTATIC, GATE, "send", "(Ljava/lang/Object;Ljava/lang/String;)V", false);
                m.visitInsn(RETURN);
                m.visitMaxs(2, 2);
                m.visitEnd();
                super.visitEnd();
            }
        }, 0);
        Files.write(Paths.get(args[1]), writer.toByteArray());
    }
}

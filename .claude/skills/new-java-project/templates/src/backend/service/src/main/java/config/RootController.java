package <BASE_PACKAGE>.config;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 服务说明与健康检查端点。
 *
 * /api/<SERVICE_NAME>/health 是部署规范统一要求的健康检查路径（specs/deployment-common.md 第六节），
 * scripts/deploy.sh 启动后轮询它判定"服务已就绪"，nginx 站点配置把同一路径透出到对外前缀。
 *
 * 这里不自定义 Actuator 的 base-path：Actuator 留在默认 /actuator/* 下供本机深检
 * （含数据库连通性，对外 show-details=never），本端点只回答"进程能否服务"。
 * Spring Boot 在 Web 容器开始接流量之前已完成 Flyway 迁移与连接池初始化，
 * 因此首次 200 即代表 schema 就绪，够用且不会因为数据库抖动把已运行的实例判死。
 */
@RestController
@RequestMapping("/api/<SERVICE_NAME>")
public class RootController {

    /**
     * 健康检查：部署脚本与监控探活使用，必须无外部依赖、恒为 200。
     */
    @GetMapping("/health")
    public Map<String, Object> health() {
        return Map.of(
            "status", "UP",
            "service", "<SERVICE_NAME>"
        );
    }

    /**
     * 服务入口说明：列出本服务的根路径，便于人工核对服务是否上线、叫什么名字。
     */
    @GetMapping
    public Map<String, Object> info() {
        return Map.of(
            "service", "<SERVICE_NAME>",
            "health", "/api/<SERVICE_NAME>/health",
            "docs", "/swagger-ui/index.html"
        );
    }
}

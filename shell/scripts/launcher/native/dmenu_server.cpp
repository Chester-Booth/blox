#include <cerrno>
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <utility>
#include <variant>
#include <vector>

namespace {

constexpr std::size_t max_request = 1024 * 1024;
constexpr std::size_t max_items = 10'000;

struct Json {
    using Object = std::map<std::string, Json>;
    using Array = std::vector<Json>;
    enum class Type { null_value, boolean, number, string, array, object };

    Type type = Type::null_value;
    bool boolean_value = false;
    std::int64_t number_value = 0;
    std::string string_value;
    Array array_value;
    Object object_value;

    static Json boolean(bool value) {
        Json result;
        result.type = Type::boolean;
        result.boolean_value = value;
        return result;
    }

    static Json number(std::int64_t value) {
        Json result;
        result.type = Type::number;
        result.number_value = value;
        return result;
    }

    static Json string(std::string value) {
        Json result;
        result.type = Type::string;
        result.string_value = std::move(value);
        return result;
    }

    static Json array(Array value) {
        Json result;
        result.type = Type::array;
        result.array_value = std::move(value);
        return result;
    }

    static Json object(Object value) {
        Json result;
        result.type = Type::object;
        result.object_value = std::move(value);
        return result;
    }
};

class Parser {
public:
    explicit Parser(const std::string& input) : input_(input) {}

    std::optional<Json> parse() {
        auto value = parse_value();
        skip_space();
        if (!value || position_ != input_.size())
            return std::nullopt;
        return value;
    }

private:
    const std::string& input_;
    std::size_t position_ = 0;

    void skip_space() {
        while (position_ < input_.size() && (input_[position_] == ' ' || input_[position_] == '\n' || input_[position_] == '\r' || input_[position_] == '\t'))
            ++position_;
    }

    bool take(const char* expected) {
        const std::string value(expected);
        if (input_.compare(position_, value.size(), value) != 0)
            return false;
        position_ += value.size();
        return true;
    }

    std::optional<Json> parse_value() {
        skip_space();
        if (position_ >= input_.size())
            return std::nullopt;
        switch (input_[position_]) {
        case 'n':
            return take("null") ? std::optional<Json>(Json{}) : std::nullopt;
        case 't':
            return take("true") ? std::optional<Json>(Json::boolean(true)) : std::nullopt;
        case 'f':
            return take("false") ? std::optional<Json>(Json::boolean(false)) : std::nullopt;
        case '"': {
            auto value = parse_string();
            return value ? std::optional<Json>(Json::string(*value)) : std::nullopt;
        }
        case '[':
            return parse_array();
        case '{':
            return parse_object();
        default:
            if (input_[position_] == '-' || (input_[position_] >= '0' && input_[position_] <= '9'))
                return parse_number();
            return std::nullopt;
        }
    }

    static void append_codepoint(std::string& output, std::uint32_t codepoint) {
        if (codepoint <= 0x7f) {
            output.push_back(static_cast<char>(codepoint));
        } else if (codepoint <= 0x7ff) {
            output.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
            output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        } else if (codepoint <= 0xffff) {
            output.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
            output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        } else if (codepoint <= 0x10ffff) {
            output.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
            output.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
    }

    std::optional<std::string> parse_string() {
        if (position_ >= input_.size() || input_[position_] != '"')
            return std::nullopt;
        ++position_;
        std::string output;
        while (position_ < input_.size()) {
            const unsigned char byte = static_cast<unsigned char>(input_[position_++]);
            if (byte == '"')
                return output;
            if (byte == '\\') {
                if (position_ >= input_.size())
                    return std::nullopt;
                const char escaped = input_[position_++];
                switch (escaped) {
                case '"': output.push_back('"'); break;
                case '\\': output.push_back('\\'); break;
                case '/': output.push_back('/'); break;
                case 'b': output.push_back('\b'); break;
                case 'f': output.push_back('\f'); break;
                case 'n': output.push_back('\n'); break;
                case 'r': output.push_back('\r'); break;
                case 't': output.push_back('\t'); break;
                case 'u': {
                    if (position_ + 4 > input_.size())
                        return std::nullopt;
                    std::uint32_t codepoint = 0;
                    for (int index = 0; index < 4; ++index) {
                        const char digit = input_[position_++];
                        codepoint <<= 4;
                        if (digit >= '0' && digit <= '9') codepoint += digit - '0';
                        else if (digit >= 'a' && digit <= 'f') codepoint += digit - 'a' + 10;
                        else if (digit >= 'A' && digit <= 'F') codepoint += digit - 'A' + 10;
                        else return std::nullopt;
                    }
                    append_codepoint(output, codepoint);
                    break;
                }
                default: return std::nullopt;
                }
            } else if (byte < 0x20) {
                return std::nullopt;
            } else {
                output.push_back(static_cast<char>(byte));
            }
        }
        return std::nullopt;
    }

    std::optional<Json> parse_array() {
        ++position_;
        Json::Array values;
        skip_space();
        if (position_ < input_.size() && input_[position_] == ']') {
            ++position_;
            return Json::array(std::move(values));
        }
        while (true) {
            auto value = parse_value();
            if (!value)
                return std::nullopt;
            values.push_back(std::move(*value));
            skip_space();
            if (position_ >= input_.size())
                return std::nullopt;
            if (input_[position_] == ',') {
                ++position_;
                continue;
            }
            if (input_[position_] == ']') {
                ++position_;
                return Json::array(std::move(values));
            }
            return std::nullopt;
        }
    }

    std::optional<Json> parse_object() {
        ++position_;
        Json::Object values;
        skip_space();
        if (position_ < input_.size() && input_[position_] == '}') {
            ++position_;
            return Json::object(std::move(values));
        }
        while (true) {
            skip_space();
            auto key = parse_string();
            if (!key)
                return std::nullopt;
            skip_space();
            if (position_ >= input_.size() || input_[position_] != ':')
                return std::nullopt;
            ++position_;
            auto value = parse_value();
            if (!value)
                return std::nullopt;
            values[*key] = std::move(*value);
            skip_space();
            if (position_ >= input_.size())
                return std::nullopt;
            if (input_[position_] == ',') {
                ++position_;
                continue;
            }
            if (input_[position_] == '}') {
                ++position_;
                return Json::object(std::move(values));
            }
            return std::nullopt;
        }
    }

    std::optional<Json> parse_number() {
        const auto start = position_;
        if (input_[position_] == '-')
            ++position_;
        while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9')
            ++position_;
        try {
            return Json::number(std::stoll(input_.substr(start, position_ - start)));
        } catch (...) {
            return std::nullopt;
        }
    }
};

std::string escape(const std::string& value) {
    std::string output = "\"";
    for (unsigned char character : value) {
        switch (character) {
        case '"': output += "\\\""; break;
        case '\\': output += "\\\\"; break;
        case '\n': output += "\\n"; break;
        case '\r': output += "\\r"; break;
        case '\t': output += "\\t"; break;
        default:
            if (character < 0x20) {
                constexpr char digits[] = "0123456789abcdef";
                output += "\\u00";
                output += digits[character >> 4];
                output += digits[character & 0xf];
            } else {
                output.push_back(static_cast<char>(character));
            }
        }
    }
    output += '"';
    return output;
}

std::string encode(const Json& value) {
    switch (value.type) {
    case Json::Type::null_value: return "null";
    case Json::Type::boolean: return value.boolean_value ? "true" : "false";
    case Json::Type::number: return std::to_string(value.number_value);
    case Json::Type::string: return escape(value.string_value);
    case Json::Type::array: {
        std::string output = "[";
        for (std::size_t index = 0; index < value.array_value.size(); ++index) {
            if (index) output += ',';
            output += encode(value.array_value[index]);
        }
        return output + ']';
    }
    case Json::Type::object: {
        std::string output = "{";
        std::size_t index = 0;
        for (const auto& [key, child] : value.object_value) {
            if (index++) output += ',';
            output += escape(key) + ':' + encode(child);
        }
        return output + '}';
    }
    }
    return "null";
}

const Json* field(const Json& value, const std::string& name) {
    if (value.type != Json::Type::object)
        return nullptr;
    const auto found = value.object_value.find(name);
    return found == value.object_value.end() ? nullptr : &found->second;
}

bool valid_options(const Json& value, std::vector<std::string>* result = nullptr) {
    const auto version = field(value, "version");
    const auto options = field(value, "options");
    if (!version || version->type != Json::Type::number || version->number_value != 1 || !options || options->type != Json::Type::array || options->array_value.size() > max_items)
        return false;
    if (result)
        result->clear();
    for (const auto& option : options->array_value) {
        if (option.type != Json::Type::string)
            return false;
        if (result)
            result->push_back(option.string_value);
    }
    return true;
}

std::optional<Json> request(const std::string& line) {
    auto value = Parser(line).parse();
    if (!value || !valid_options(*value) || value->type != Json::Type::object)
        return std::nullopt;
    value->object_value["event"] = Json::string("request");
    return value;
}

std::optional<Json> update(const std::string& line) {
    auto value = Parser(line).parse();
    const auto event = value ? field(*value, "event") : nullptr;
    if (!value || !event || event->type != Json::Type::string || event->string_value != "options")
        return std::nullopt;
    std::vector<std::string> options;
    if (!valid_options(*value, &options))
        return std::nullopt;
    Json::Object result;
    result["event"] = Json::string("update");
    Json::Array encoded_options;
    for (auto& option : options) encoded_options.push_back(Json::string(std::move(option)));
    result["options"] = Json::array(std::move(encoded_options));
    return Json::object(std::move(result));
}

std::optional<Json> response(const std::string& line) {
    auto value = Parser(line).parse();
    if (!value || value->type != Json::Type::object)
        return std::nullopt;
    const auto cancelled = field(*value, "cancelled");
    const auto selected = field(*value, "value");
    if (selected && selected->type != Json::Type::string)
        return std::nullopt;
    Json::Object result;
    result["version"] = Json::number(1);
    result["ok"] = Json::boolean(!cancelled || cancelled->type != Json::Type::boolean || !cancelled->boolean_value);
    result["value"] = Json::string(selected ? selected->string_value : "");
    return Json::object(std::move(result));
}

Json error_response(const std::string& error) {
    Json::Object result;
    result["version"] = Json::number(1);
    result["ok"] = Json::boolean(false);
    result["error"] = Json::string(error);
    return Json::object(std::move(result));
}

void send_value(int fd, const Json& value) {
    const auto line = encode(value) + '\n';
    const auto* data = line.data();
    std::size_t remaining = line.size();
    while (remaining > 0) {
        const auto written = send(fd, data, remaining, MSG_NOSIGNAL);
        if (written <= 0)
            return;
        data += written;
        remaining -= static_cast<std::size_t>(written);
    }
}

struct Client {
    int fd;
    std::string buffer;
};

void remove_client(std::vector<Client>& clients, int& active, std::size_t index, bool announce) {
    const bool was_active = active == static_cast<int>(index);
    close(clients[index].fd);
    clients.erase(clients.begin() + static_cast<std::ptrdiff_t>(index));
    if (active == static_cast<int>(index)) active = -1;
    else if (active > static_cast<int>(index)) --active;
    if (was_active && announce) {
        std::cout << "{\"event\":\"abandoned\"}" << std::endl;
    }
}

bool nonblocking(int fd) {
    const auto flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

} // namespace

int main() {
    const char* runtime_value = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime_value)
        return 1;
    const std::filesystem::path runtime = std::filesystem::path(runtime_value) / "blox-launcher";
    const auto socket_path = runtime / "dmenu.sock";
    std::error_code error;
    std::filesystem::create_directories(runtime, error);
    if (error || chmod(runtime.c_str(), 0700) != 0)
        return 1;
    std::filesystem::remove(socket_path, error);

    const int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0)
        return 1;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (socket_path.string().size() >= sizeof(address.sun_path)) {
        close(listener);
        return 1;
    }
    const auto socket_name = socket_path.string();
    std::copy(socket_name.begin(), socket_name.end(), address.sun_path);
    if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 || chmod(socket_path.c_str(), 0600) != 0 || listen(listener, 4) != 0 || !nonblocking(listener)) {
        close(listener);
        std::filesystem::remove(socket_path, error);
        return 1;
    }

    std::vector<Client> clients;
    int active = -1;
    std::string stdin_buffer;
    bool running = true;
    while (running) {
        std::vector<pollfd> descriptors;
        descriptors.push_back({listener, POLLIN, 0});
        descriptors.push_back({STDIN_FILENO, POLLIN, 0});
        for (const auto& client : clients)
            descriptors.push_back({client.fd, POLLIN, 0});
        if (poll(descriptors.data(), descriptors.size(), -1) < 0)
            break;

        if (descriptors[1].revents & (POLLIN | POLLHUP)) {
            char chunk[8192];
            const auto size = read(STDIN_FILENO, chunk, sizeof(chunk));
            if (size <= 0) {
                running = false;
            } else {
                stdin_buffer.append(chunk, static_cast<std::size_t>(size));
                while (true) {
                    const auto end = stdin_buffer.find('\n');
                    if (end == std::string::npos)
                        break;
                    const auto line = stdin_buffer.substr(0, end);
                    stdin_buffer.erase(0, end + 1);
                    if (active >= 0 && active < static_cast<int>(clients.size())) {
                        const auto value = response(line);
                        send_value(clients[active].fd, value ? *value : error_response("invalid response"));
                        remove_client(clients, active, static_cast<std::size_t>(active), false);
                    }
                }
            }
        }

        if (descriptors[0].revents & (POLLIN | POLLERR)) {
            while (true) {
                const int client = accept(listener, nullptr, nullptr);
                if (client < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                    running = false;
                    break;
                }
                if (!nonblocking(client)) {
                    close(client);
                    continue;
                }
                if (active >= 0) {
                    send_value(client, error_response("busy"));
                    close(client);
                } else {
                    clients.push_back({client, {}});
                }
            }
        }

        std::vector<std::size_t> ready;
        for (std::size_t index = 2; index < descriptors.size(); ++index) {
            if (descriptors[index].revents & (POLLIN | POLLERR | POLLHUP))
                ready.push_back(index - 2);
        }
        for (auto ready_index = ready.rbegin(); ready_index != ready.rend(); ++ready_index) {
            const auto index = *ready_index;
            if (index >= clients.size()) continue;
            char chunk[65536];
            bool closed = false;
            while (true) {
                const auto size = recv(clients[index].fd, chunk, sizeof(chunk), 0);
                if (size == 0) { closed = true; break; }
                if (size < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                    closed = true;
                    break;
                }
                clients[index].buffer.append(chunk, static_cast<std::size_t>(size));
                if (clients[index].buffer.size() > max_request) { closed = true; break; }
            }
            if (closed) {
                remove_client(clients, active, index, active == static_cast<int>(index));
                continue;
            }
            while (index < clients.size()) {
                const auto end = clients[index].buffer.find('\n');
                if (end == std::string::npos) break;
                const auto line = clients[index].buffer.substr(0, end);
                clients[index].buffer.erase(0, end + 1);
                if (active == static_cast<int>(index)) {
                    const auto value = update(line);
                    if (!value) {
                        send_value(clients[index].fd, error_response("invalid update"));
                        remove_client(clients, active, index, true);
                        break;
                    }
                    std::cout << encode(*value) << std::endl;
                } else if (active >= 0) {
                    send_value(clients[index].fd, error_response("busy"));
                    remove_client(clients, active, index, false);
                    break;
                } else {
                    const auto value = request(line);
                    if (!value) {
                        send_value(clients[index].fd, error_response("invalid request"));
                        remove_client(clients, active, index, false);
                        break;
                    }
                    active = static_cast<int>(index);
                    std::cout << encode(*value) << std::endl;
                }
            }
        }
    }

    for (const auto& client : clients) close(client.fd);
    close(listener);
    std::filesystem::remove(socket_path, error);
    return 0;
}
